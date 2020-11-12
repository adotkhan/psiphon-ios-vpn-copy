/*
 * Copyright (c) 2020, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

import Foundation
import PsiApi
import AppStoreIAP
import PsiCashClient
import Utilities
import ReactiveSwift

enum MainViewAction: Equatable {

    case applicationDidBecomeActive

    // Alert message actions
    case presentAlert(AlertEvent)

    case _presentAlertResult(newState: PresentationState<AlertEvent>)

    case _alertButtonTapped(AlertEvent, AlertAction)

    case presentPsiCashScreen(initialTab: PsiCashScreenTab)
    case dismissedPsiCashScreen

    case psiCashViewAction(PsiCashViewAction)
}

struct MainViewState: Equatable {
    /// - Note: Two elements of`alertMessages` are equal if their `AlertEvent` values are equal.
    var alertMessages = Set<PresentationState<AlertEvent>>()
    var psiCashViewState: PsiCashViewState? = nil
}

struct MainViewReducerState: Equatable {
    var mainView: MainViewState
    let psiCashAccountType: PsiCashAccountType?
    let appLifecycle: AppLifecycle
}

extension MainViewReducerState {
    var psiCashViewReducerState: PsiCashViewReducerState? {
        get {
            guard let psiCashState = self.mainView.psiCashViewState else {
                return nil 
            }
            return PsiCashViewReducerState(
                viewState: psiCashState,
                psiCashAccountType: self.psiCashAccountType
            )
        }
        set {
            self.mainView.psiCashViewState = newValue?.viewState
        }
    }
}

struct MainViewEnvironment {
    let psiCashViewEnvironment: PsiCashViewEnvironment
    let getTopPresentedViewController: () -> UIViewController
    let feedbackLogger: FeedbackLogger
    let rxDateScheduler: DateScheduler
    let makePsiCashViewController: () -> PsiCashViewController
    let makeSubscriptionViewController: () -> UIViewController
}

let mainViewReducer = Reducer<MainViewReducerState, MainViewAction, MainViewEnvironment> {
    state, action, environment in
    
    switch action {

    case .applicationDidBecomeActive:
        let failedMessages = state.mainView.alertMessages.filter {
            if case .failedToPresent(_) = $0.state {
                return true
            } else {
                return false
            }
        }

        return failedMessages.map {
            Effect(value: .presentAlert($0.viewModel))
        }


    case let .presentAlert(alertEvent):

        // This guard ensures that alert dialog is presented successfully,
        // given app's current lifecycle.
        // If the app is in the background, view controllers can be presented, but
        // not seen by the user.
        // Also if an alert is presented while the app just launched, but before
        // the applicationDidBecomeActive(_:) callback, safePresent(_:::) will return
        // true, however UIKit will fail to present the view controller.
        guard case .didBecomeActive = state.appLifecycle else {
            state.mainView.alertMessages.update(
                with: PresentationState(alertEvent, state: .failedToPresent(.applicationNotActive))
            )
            return []
        }

        let maybeMatchingEvent = state.mainView.alertMessages.first {
            $0.viewModel == alertEvent
        }

        switch maybeMatchingEvent?.state {
        case .notPresented, .willPresent, .didPresent:
            // Alert was presented, or will be presented.
            return []

        case .none, .failedToPresent(_):
            // Alert is either new, or failed to present previously.
            state.mainView.alertMessages.update(
                with: PresentationState(alertEvent, state: .notPresented)
            )

            return [
                environment.feedbackLogger.log(.info, "Presenting alert: \(alertEvent)")
                    .mapNever(),

                // Creates a UIAlertController based on the given alertEvent, and presents it
                // on top of the top most presented view controller.
                Effect { observer, _ in

                    let alertController = UIAlertController
                        .makeUIAlertController(alertEvent: alertEvent) { alertEvent, alertAction in
                            observer.send(value: ._alertButtonTapped(alertEvent, alertAction))

                            // Completes the signal as the UIAlertController has been dismissed.
                            observer.sendCompleted()
                        }

                    let topVC = environment.getTopPresentedViewController()

                    let success = topVC.safePresent(
                        alertController,
                        animated: true,
                        viewDidAppearHandler: {
                            observer.send(value: ._presentAlertResult(
                                            newState: PresentationState(alertEvent,
                                                                        state: .didPresent)))

                            // `onActionButtonTapped` closure of makeUIAlertController
                            // is expected to be called after (this) `completion` closure is called.
                        }
                    )

                    if success {
                        observer.send(value: ._presentAlertResult(
                                        newState: PresentationState(alertEvent,
                                                                    state: .willPresent)))
                        // safePresent `completion` callback is expected to be called,
                        // after UIKit has finished presenting the alertController.
                    } else {
                        observer.send(
                            value: ._presentAlertResult(
                                newState: PresentationState(
                                    alertEvent, state: .failedToPresent(.safePresentFailed))))

                        // Completes the signal if failed to present alertController,
                        // as there will be no more events to send on the stream.
                        observer.sendCompleted()
                    }
                }
            ]
        }

    case let ._presentAlertResult(newState: newState):

        guard
            let oldMember = state.mainView.alertMessages.update(with: newState)
        else {
            environment.feedbackLogger.fatalError("unexpected state")
            return []
        }

        // Verifies if oldMember has the expected value given newState.
        let expectedOldMemberState: PresentationState<AlertEvent>.State?
        switch newState.state {
        case .notPresented:
            expectedOldMemberState = nil

        case .failedToPresent, .willPresent:
            expectedOldMemberState = .notPresented

        case .didPresent:
            expectedOldMemberState = .willPresent
        }

        guard oldMember.state == expectedOldMemberState else {
            environment.feedbackLogger.fatalError("unexpected state")
            return []
        }

        return []

    case let ._alertButtonTapped(alertEvent, alertAction):

        // State check.
        let expectedCurrentState = PresentationState(alertEvent, state: .didPresent)
        guard state.mainView.alertMessages.contains(expectedCurrentState) else {
            environment.feedbackLogger.fatalError("unexpected state")
            return []
        }

        switch alertAction {
        case .dismissTapped:

            let alertType: AlertType = alertEvent.wrapped
            switch alertType {
            case .psiCashAccountAlert(.loginSuccessAlert(lastTrackerMerge: _)):
                // Dismisses PsiCashAccountViewController if it is top of the stack.
                return [
                    .fireAndForget {
                        let topVC = environment.getTopPresentedViewController()
                        let searchResult = topVC.traversePresentingStackFor(
                            type: PsiCashAccountViewController.self,
                            searchChildren: true
                        )

                        switch searchResult {
                        case .notPresent:
                            // Nop.
                            return
                        case .presentInStack(let viewController),
                             .presentTopOfStack(let viewController):
                            viewController.dismiss(animated: true, completion: nil)
                        }
                    }
                ]

            default:
                return []
            }

        case .addPsiCashTapped:
            // Note that "Add PsiCash" tab is only displayed only if PsiCashViewController
            // is already presented (i.e. state.mainView.psiCashViewState is not nil).
            return [ Effect(value: .psiCashViewAction(.switchTabs(.addPsiCash))) ]

        case let .disallowedTrafficAlertAction(a):
            switch a {
            case .speedBoostTapped:
                return [ Effect(value: .presentPsiCashScreen(initialTab: .speedBoost)) ]
            case .subscriptionTapped:

                return [
                    .fireAndForget {
                        let topVC = environment.getTopPresentedViewController()

                        let found = topVC
                            .traversePresentingStackFor(type: IAPViewController.self, searchChildren: true)

                        switch found {
                        case .presentTopOfStack(_), .presentInStack(_):
                            // NO-OP
                            break
                        case .notPresent:
                            let vc = environment.makeSubscriptionViewController()
                            topVC.safePresent(vc, animated: true, viewDidAppearHandler: nil)
                        }
                    }
                ]
            }
        }

    case let .presentPsiCashScreen(initialTab):
        // If psiCashViewState is not nil, it implies the PsiCashViewController is presented.
        guard case .none = state.mainView.psiCashViewState else {
            return []
        }

        state.mainView.psiCashViewState = PsiCashViewState(
            psiCashIAPPurchaseRequestState: .none,
            activeTab: initialTab,
            isPsiCashAccountScreenShown: false
        )

        return [
            .fireAndForget {
                let topVC = environment.getTopPresentedViewController()
                let searchResult = topVC.traversePresentingStackFor(type: PsiCashViewController.self)

                switch searchResult {
                case .notPresent:
                    let psiCashViewController = environment.makePsiCashViewController()

                    topVC.safePresent(psiCashViewController,
                                      animated: true,
                                      viewDidAppearHandler: nil)

                case .presentInStack(_),
                     .presentTopOfStack(_):
                    // Nop.
                    break
                }
            }
        ]

    case .dismissedPsiCashScreen:
        // If psiCashViewState is nil, it implies the PsiCashViewController not presented.
        guard case .some(_) = state.mainView.psiCashViewState else {
            return []
        }

        state.mainView.psiCashViewState = .none

        return []

    case .psiCashViewAction(let psiCashAction):
        switch state.psiCashViewReducerState {
        case .none:
            return []
        case .some(_):
            let effects = psiCashViewReducer(
                &state.psiCashViewReducerState!, psiCashAction, environment.psiCashViewEnvironment
            )
            
            return effects.map { $0.map { MainViewAction.psiCashViewAction($0) } }
        }

    }
    
}
