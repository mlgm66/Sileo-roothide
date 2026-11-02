//
//  FeaturedInfoFooterView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation

class FeaturedInfoFooterView: FeaturedBaseView {
    let label: UILabel
    
    required init?(dictionary: [String: Any], viewController: UIViewController, tintColor: UIColor, isActionable: Bool) {
        label = UILabel(frame: .zero)
        
        super.init(dictionary: dictionary, viewController: viewController, tintColor: tintColor, isActionable: isActionable)
        
        label.textAlignment = .center
        self.addSubview(label)
        
        let sileoVersion = FeaturedInfoFooterView.package?.version
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? String(localizationKey: "Unknown")
        
        let platform = UIDevice.current.platform
        let systemVersion = UIDevice.current.systemVersion

        label.text = "\(platform), iOS \(systemVersion), Sileo \(sileoVersion)\n\(Jailbreak.current.rawValue) | \(Jailbreak.bootstrap.rawValue)"
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .lightGray
        label.numberOfLines = 3
        label.adjustsFontSizeToFitWidth = true
    }
    
    static var package: Package? {
        switch Bundle.main.bundleIdentifier {
        case "org.coolstar.SileoBeta": return PackageListManager.shared.installedPackage(identifier: "org.mlgm.sileobeta")
        case "org.coolstar.SileoNightly": return PackageListManager.shared.installedPackage(identifier: "org.mlgm.sileonightly")
        default: return PackageListManager.shared.installedPackage(identifier: "org.mlgm.sileo")
        }
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func depictionHeight(width: CGFloat) -> CGFloat {
        48
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(origin: self.bounds.origin,
                             size: CGSize(width: self.bounds.width, height: 39.5))
    }
}
