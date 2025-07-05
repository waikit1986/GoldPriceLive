//
//  ContentView.swift
//  GoldPriveLive
//
//  Created by Low Wai Kit on 7/5/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appleSignInVM: AppleSignInVM
    
    var body: some View {
        AppleSignInView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppleSignInVM())
}
