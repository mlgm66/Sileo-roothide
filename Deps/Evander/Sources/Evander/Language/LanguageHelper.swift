//
//  LanguageHelper.swift
//  Sileo
//
//  Created by Andromeda on 03/08/2021.
//  Copyright © 2021 Sileo Team. All rights reserved.
//

import CommonCrypto
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

//the language for current app, not the current system language=(UI Layout direction)
final public class LanguageHelper {
    
    public static let shared = LanguageHelper()
    public let availableLanguages: [Language]
    public var primaryBundle: Bundle?
    public var locale: Locale?
    public var isRtl: Bool? {
        didSet {
            guard let isRtl else { return }
//            #if canImport(UIKit)
//            UIApplication.overrideLayout(rtl: isRtl)
//            #endif
        }
    }
    
    init() {
        var locales = Bundle.main.localizations
        locales.removeAll { $0 == "Base" }
        locales.sort { $0 < $1 }
        
        let currentLocale = NSLocale.current as NSLocale
        var temp = [Language]()
        for language in locales {
            let locale = NSLocale(localeIdentifier: language)
            let localizedDisplay: String
            let display: String
            if language == "en-PT" {
                localizedDisplay = "Pirate English"
                display = "Pirate English"
            } else {
                localizedDisplay = currentLocale.displayName(forKey: .identifier, value: language)?.capitalized(with: currentLocale as Locale) ?? language
                display = locale.displayName(forKey: .identifier, value: language)?.capitalized(with: locale as Locale) ?? language
            }
            temp.append(Language(displayName: display, localizedDisplay: localizedDisplay, key: language))
        }
        availableLanguages = temp

        var selectedLanguage: String
        
        // Write an exception for en-PT because its supposed to be English Portugal
        if currentLocale.languageCode == "en-PT" && UserDefaults.standard.bool(forKey: "UseSystemLanguage", fallback: true) {
            selectedLanguage = "Base"
            UserDefaults.standard.setValue("Base", forKey: "SelectedLanguage")
        } else if UserDefaults.standard.bool(forKey: "UseSystemLanguage", fallback: true) {
            let locale = Locale.current.identifier
            self.isRtl = Locale.characterDirection(forLanguage: locale) == .rightToLeft
            return
        // swiftlint:disable:next identifier_name
        } else if let _selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") {
            selectedLanguage = _selectedLanguage
        } else {
            selectedLanguage = "Base"
            UserDefaults.standard.setValue("Base", forKey: "SelectedLanguage")
        }
        
        if let path = Bundle.main.path(forResource: selectedLanguage, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            self.isRtl = Locale.characterDirection(forLanguage: selectedLanguage) == .rightToLeft
            self.primaryBundle = bundle
            self.locale = Locale(identifier: selectedLanguage == "Base" ? "en" : selectedLanguage)
            return
        }
        
        guard selectedLanguage != "Base" else { return }
        if let path = Bundle.main.path(forResource: "Base", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            self.primaryBundle = bundle
            self.isRtl = false
            self.locale = Locale(identifier: "en")
            return
        }
    }
    
}
