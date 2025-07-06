//
//  ContentView.swift
//  GoldPriveLive
//
//  Created by Low Wai Kit on 7/5/25.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject var appleSignInVM: AppleSignInVM
    
    var body: some View {
        AppleSignInView()
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        print("active back")
                        appleSignInVM.startTokenExpiryTimer()
                        appleSignInVM.startRefreshTokenExpiryTimer()
                    }
                }
            }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppleSignInVM())
}
