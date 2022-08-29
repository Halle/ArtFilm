//
//  OffcutsCamApp.swift
//  OffcutsCam
//
//  Created by Halle Winkler on 10.08.22.
//

import SwiftUI

@main
struct OffcutsCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(systemExtensionRequestManager: SystemExtensionRequestManager(logText: ""), propertyManager: CustomPropertyManager(), outputImageManager: OutputImageManager())
                .frame(minWidth: 1280, maxWidth: 1360, minHeight: 900, maxHeight: 940)
        }
    }
}
