//
//  GoldPriveLiveApp.swift
//  GoldPriveLive
//
//  Created by Low Wai Kit on 7/5/25.
//

import SwiftUI

@main
struct GoldPriveLiveApp: App {
    @StateObject var appleSignInVM = AppleSignInVM()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appleSignInVM)
        }
    }
}
