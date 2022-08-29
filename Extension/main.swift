//
//  main.swift
//  Extension
//
//  Created by Halle Winkler on 10.08.22.
//

import CoreMediaIO
import Foundation

let providerSource = ExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
