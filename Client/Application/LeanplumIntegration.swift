/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import AdSupport
import Shared
import Leanplum

private let LPEnvironmentKey = "LeanplumEnvironment"
private let LPAppIdKey = "LeanplumAppId"
private let LPKeyKey = "LeanplumKey"
private let AppRequestedUserNotificationsPrefKey = "applicationDidRequestUserNotificationPermissionPrefKey"

// FxA Custom Leanplum message template for A/B testing push notifications.
private struct LPMessage {
    static let FxAPrePush = "FxA Prepush v1"
    static let ArgAcceptAction = "Accept action"
    static let ArgCancelAction = "Cancel action"
    static let ArgTitleText = "Title.Text"
    static let ArgTitleColor = "Title.Color"
    static let ArgMessageText = "Message.Text"
    static let ArgMessageColor = "Message.Color"
    static let ArgAcceptButtonText = "Accept button.Text"
    static let ArgCancelButtonText = "Cancel button.Text"
    static let ArgCancelButtonTextColor = "Cancel button.Text color"
    // These defaults are overridden though Leanplum webUI
    static let DefaultAskToAskTitle = NSLocalizedString("Firefox Sync Requires Push", comment: "Default push to ask title")
    static let DefaultAskToAskMessage = NSLocalizedString("Firefox will stay in sync faster with Push Notifications enabled.", comment: "Default push to ask message")
    static let DefaultOkButtonText = NSLocalizedString("Enable Push", comment: "Default push alert ok button text")
    static let DefaultLaterButtonText = NSLocalizedString("Don't Enable", comment: "Default push alert cancel button text")
}

private let log = Logger.browserLogger

private enum LPEnvironment: String {
    case development
    case production
}

enum LPEvent: String {
    case firstRun = "E_First_Run"
    case secondRun = "E_Second_Run"
    case openedApp = "E_Opened_App"
    case dismissedOnboarding = "E_Dismissed_Onboarding"
    case openedLogins = "Opened Login Manager"
    case openedBookmark = "E_Opened_Bookmark"
    case openedNewTab = "E_Opened_New_Tab"
    case openedPocketStory = "E_Opened_Pocket_Story"
    case interactWithURLBar = "E_Interact_With_Search_URL_Area"
    case savedBookmark = "E_Saved_Bookmark"
    case openedTelephoneLink = "Opened Telephone Link"
    case openedMailtoLink = "E_Opened_Mailto_Link"
    case saveImage = "E_Download_Media_Saved_Image"
    case savedLoginAndPassword = "E_Saved_Login_And_Password"
    case clearPrivateData = "E_Cleared_Private_Data"
    case downloadedFocus = "E_User_Downloaded_Focus"
    case downloadedPocket = "E_User_Downloaded_Pocket"
    case userSharedWebpage = "E_User_Tapped_Share_Button"
    case signsInFxa = "E_User_Signed_In_To_FxA"
    case useReaderView = "E_User_Used_Reader_View"
    case trackingProtectionSettings = "E_Tracking_Protection_Settings_Changed"
}

struct LPAttributeKey {
    static let focusInstalled = "Focus Installed"
    static let klarInstalled = "Klar Installed"
    static let signedInSync = "Signed In Sync"
    static let mailtoIsDefault = "Mailto Is Default"
    static let pocketInstalled = "Pocket Installed"
    static let telemetryOptIn = "Telemetry Opt In"
}


private let SupportedLocales = ["en_US", "de_DE", "en_GB", "en_CA", "en_AU", "zh_TW", "en_HK", "en_SG",
                        "fr_FR", "it_IT", "id_ID", "id_ID", "pt_BR", "pl_PL", "ru_RU", "es_ES", "es_MX"]

private struct LPSettings {
    var environment: LPEnvironment
    var appId: String
    var key: String
}

class LeanPlumClient {
    static let shared = LeanPlumClient()

    // Setup
    private weak var profile: Profile?
    private var enabled: Bool = true
    
    private func shouldSendToLP() -> Bool {
        // Need to be run on main thread since isInPrivateMode requires to be on the main thread.
        assert(Thread.isMainThread)
        return enabled && Leanplum.hasStarted() && !UIApplication.isInPrivateMode
    }

    static func shouldEnable(profile: Profile) -> Bool {
        return AppConstants.MOZ_ENABLE_LEANPLUM && (profile.prefs.boolForKey(AppConstants.PrefSendUsageData) ?? true)
    }

    func setup(profile: Profile) {
        self.profile = profile
    }

    private func setupDefaults() {
        if profile?.prefs.boolForKey(PrefsKeys.HasFocusInstalled) == nil {
            profile?.prefs.setBool(focusInstalled(), forKey: PrefsKeys.HasFocusInstalled)
        }

        if profile?.prefs.boolForKey(PrefsKeys.HasPocketInstalled) == nil {
            profile?.prefs.setBool(pocketInstalled(), forKey: PrefsKeys.HasPocketInstalled)
        }
    }

    fileprivate func start() {
        guard let settings = getSettings(), SupportedLocales.contains(Locale.current.identifier), !Leanplum.hasStarted() else {
            log.error("LeanplumIntegration - Could not be started")
            return
        }

        switch settings.environment {
            case .development:
                log.info("LeanplumIntegration - Setting up for Development")
                Leanplum.setDeviceId(UIDevice.current.identifierForVendor?.uuidString)
                Leanplum.setAppId(settings.appId, withDevelopmentKey: settings.key)
            case .production:
                log.info("LeanplumIntegration - Setting up for Production")
                Leanplum.setAppId(settings.appId, withProductionKey: settings.key)
        }

        Leanplum.syncResourcesAsync(true)
        setupDefaults()

        let attributes: [AnyHashable: Any] = [
            LPAttributeKey.mailtoIsDefault: mailtoIsDefault(),
            LPAttributeKey.focusInstalled: focusInstalled(),
            LPAttributeKey.klarInstalled: klarInstalled(),
            LPAttributeKey.pocketInstalled: pocketInstalled(),
            LPAttributeKey.signedInSync: profile?.hasAccount() ?? false
        ]

        self.setupCustomTemplates()
        
        Leanplum.start(withUserId: nil, userAttributes: attributes, responseHandler: { _ in
            self.track(event: .openedApp)

            // We need to check if the app is a clean install to use for
            // preventing the What's New URL from appearing.
            if self.profile?.prefs.intForKey(IntroViewControllerSeenProfileKey) == nil {
                self.profile?.prefs.setString(AppInfo.appVersion, forKey: LatestAppVersionProfileKey)
                self.track(event: .firstRun)
            } else if self.profile?.prefs.boolForKey("SecondRun") == nil {
                self.profile?.prefs.setBool(true, forKey: "SecondRun")
                self.track(event: .secondRun)
            }

            self.checkIfAppInstalled(key: PrefsKeys.HasFocusInstalled, isAppInstalled: self.focusInstalled(), lpEvent: .downloadedFocus)
            self.checkIfAppInstalled(key: PrefsKeys.HasPocketInstalled, isAppInstalled: self.pocketInstalled(), lpEvent: .downloadedPocket)
        })
    }

    // Events
    func track(event: LPEvent, withParameters parameters: [String: AnyObject]? = nil) {
        DispatchQueue.main.ensureMainThread {
            guard self.shouldSendToLP() else {
                return
            }
            if let params = parameters {
                Leanplum.track(event.rawValue, withParameters: params)
            } else {
                Leanplum.track(event.rawValue)
            }
        }
    }

    func set(attributes: [AnyHashable: Any]) {
        DispatchQueue.main.ensureMainThread {
            if self.shouldSendToLP() {
                Leanplum.setUserAttributes(attributes)
            }
        }
    }

    func set(enabled: Bool) {
        // Setting up Test Mode stops sending things to server.
        if enabled { start() }
        self.enabled = enabled
        Leanplum.setTestModeEnabled(!enabled)
    }

    /*
     We use this to check if an app was installed _after_ a user has installed firefox
     To do this we only report when the key changes from false -> true
     If the key is not present we use isAppInstalled bool to set a default (if the app is not installed this will be false)
     On subsequent launches we check if the users pref is false and if the app is installed (via isAppInstalled)
     if the value is true the we fire the event!
     */
    private func checkIfAppInstalled(key: String, isAppInstalled: Bool, lpEvent: LPEvent) {
        if self.profile?.prefs.boolForKey(key) == nil {
            self.profile?.prefs.setBool(isAppInstalled, forKey: key)
        }

        if !(self.profile?.prefs.boolForKey(key) ?? false), isAppInstalled {
            self.profile?.prefs.setBool(isAppInstalled, forKey: key)
            self.track(event: lpEvent)
        }
    }

    private func focusInstalled() -> Bool {
        return URL(string: "firefox-focus://").flatMap { UIApplication.shared.canOpenURL($0) } ?? false
    }

    private func klarInstalled() -> Bool {
        return URL(string: "firefox-klar://").flatMap { UIApplication.shared.canOpenURL($0) } ?? false
    }

    private func pocketInstalled() -> Bool {
        return URL(string: "pocket://").flatMap { UIApplication.shared.canOpenURL($0) } ?? false
    }

    private func mailtoIsDefault() -> Bool {
        if let option = self.profile?.prefs.stringForKey(PrefsKeys.KeyMailToOption), option != "mailto:" {
            return false
        }
        return true
    }

    private func getSettings() -> LPSettings? {
        let bundle = Bundle.main
        guard let environmentString = bundle.object(forInfoDictionaryKey: LPEnvironmentKey) as? String,
              let environment = LPEnvironment(rawValue: environmentString),
              let appId = bundle.object(forInfoDictionaryKey: LPAppIdKey) as? String,
              let key = bundle.object(forInfoDictionaryKey: LPKeyKey) as? String else {
            return nil
        }
        return LPSettings(environment: environment, appId: appId, key: key)
    }
    
    // This must be called before `Leanplum.start` in order to correctly setup
    // custom message templates.
    private func setupCustomTemplates() {
        // These properties are exposed through the Leanplum web interface.
        // Ref: https://github.com/Leanplum/Leanplum-iOS-Samples/blob/master/iOS_customMessageTemplates/iOS_customMessageTemplates/LPMessageTemplates.m
        let args: [LPActionArg] = [
            LPActionArg(named: LPMessage.ArgTitleText, with: LPMessage.DefaultAskToAskTitle),
            LPActionArg(named: LPMessage.ArgTitleColor, with: UIColor.black),
            LPActionArg(named: LPMessage.ArgMessageText, with: LPMessage.DefaultAskToAskMessage),
            LPActionArg(named: LPMessage.ArgMessageColor, with: UIColor.black),
            LPActionArg(named: LPMessage.ArgAcceptButtonText, with: LPMessage.DefaultOkButtonText),
            LPActionArg(named: LPMessage.ArgCancelAction, withAction: nil),
            LPActionArg(named: LPMessage.ArgCancelButtonText, with: LPMessage.DefaultLaterButtonText),
            LPActionArg(named: LPMessage.ArgCancelButtonTextColor, with: UIColor.gray)
        ]
        
        let responder: LeanplumActionBlock = { (context) -> Bool in
            guard let context = context else {
                return false
            }
            
            // Don't display permission screen if they have already allowed/disabled push permissions
            if self.profile?.prefs.boolForKey(AppRequestedUserNotificationsPrefKey) ?? false {
                FxALoginHelper.sharedInstance.readyForSyncing()
                return false
            }
            
            // Present Alert View onto the current top view controller
            let rootViewController = UIApplication.topViewController()
            let title = NSLocalizedString(context.stringNamed(LPMessage.ArgTitleText), comment: "")
            let message = NSLocalizedString(context.stringNamed(LPMessage.ArgMessageText), comment: "")
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            
            let cancelText = NSLocalizedString(context.stringNamed(LPMessage.ArgCancelButtonText), comment: "")
            alert.addAction(UIAlertAction(title: cancelText, style: .cancel, handler: { (action) -> Void in
                // Log cancel event and call ready for syncing
                context.runTrackedActionNamed(LPMessage.ArgCancelAction)
                FxALoginHelper.sharedInstance.readyForSyncing()
            }))
            
            let acceptText = NSLocalizedString(context.stringNamed(LPMessage.ArgAcceptButtonText), comment: "")
            alert.addAction(UIAlertAction(title: acceptText, style: .default, handler: { (action) -> Void in
                // Log accept event and present push permission modal
                context.runTrackedActionNamed(LPMessage.ArgAcceptAction)
                FxALoginHelper.sharedInstance.requestUserNotifications(UIApplication.shared)
                self.profile?.prefs.setBool(true, forKey: AppRequestedUserNotificationsPrefKey)
            }))
            
            rootViewController?.present(alert, animated: true, completion: nil)
            return true
        }
        
        // Register or update the custom Leanplum message
        Leanplum.defineAction(LPMessage.FxAPrePush, of: kLeanplumActionKindMessage, withArguments: args, withOptions: [:], withResponder: responder)
    }
}

extension UIApplication {
    // Extension to get the current top most view controller
    class func topViewController(base: UIViewController? = UIApplication.shared.keyWindow?.rootViewController) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            if let selected = tab.selectedViewController {
                return topViewController(base: selected)
            }
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}
