//
//  AppleSignInVM.swift
//  Feel Buddha
//
//  Created by Low Wai Kit on 6/29/25.
//

import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI
import Security

@MainActor
class AppleSignInVM: ObservableObject {
    @AppStorage("user_id") var userID: String?
    @AppStorage("email") var email: String?
    @AppStorage("full_name") var fullName: String?
    @AppStorage("is_logged_in") var isLoggedIn: Bool = false
    @AppStorage("access_token_expires_at") private var accessTokenExpiresAt: Double?
    @AppStorage("refresh_token_expires_at") private var refreshTokenExpiresAt: Double?

    @Published var serverErrorMessage: String?

    let url = "https://3ee0-2001-d08-1c06-6604-a1b5-7a4d-f083-8669.ngrok-free.app"

    // MARK: - Apple Sign In

    func configure(request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    func handleCompletion(result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authResults):
            await handleSignInResult(authResults, nonce: currentNonce)
        case .failure(let error):
            print("Apple sign-in failed: \(error.localizedDescription)")
            serverErrorMessage = "Apple sign-in failed: \(error.localizedDescription)"
        }
    }

    private func handleSignInResult(_ authResult: ASAuthorization, nonce: String?) async {
        guard let appleIDCredential = authResult.credential as? ASAuthorizationAppleIDCredential,
              let appleIDToken = appleIDCredential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8),
              let nonce = nonce else {
            serverErrorMessage = "Missing Apple credentials"
            return
        }

        let fullName = [appleIDCredential.fullName?.givenName, appleIDCredential.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")

        await sendToBackend(idToken: idTokenString, nonce: nonce, userIdentifier: appleIDCredential.user, email: appleIDCredential.email, fullName: fullName)
    }

    private func sendToBackend(idToken: String, nonce: String, userIdentifier: String, email: String?, fullName: String?) async {
        guard let url = URL(string: "\(url)/api/apple/login") else {
            serverErrorMessage = "Invalid login URL"
            return
        }
        
        serverErrorMessage = nil

        let payload = AppleLoginPayload(id_token: idToken, nonce: nonce, user_identifier: userIdentifier, email: email, full_name: fullName)

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data) {
                    serverErrorMessage = serverError.detail
                } else {
                    serverErrorMessage = "Login failed with status \(String(describing: (response as? HTTPURLResponse)?.statusCode))"
                }
                return
            }

            let loginResponse = try JSONDecoder().decode(AppleLoginResponse.self, from: data)

            userID = loginResponse.user_id
            self.email = loginResponse.email
            self.fullName = loginResponse.username
            isLoggedIn = true

            saveToKeychain(key: "access_token", value: loginResponse.access_token)
            saveToKeychain(key: "refresh_token", value: loginResponse.refresh_token)
            accessTokenExpiresAt = loginResponse.access_token_expires_at
            refreshTokenExpiresAt = loginResponse.refresh_token_expires_at
            
            print("✅ Logged in")
            print("refresh token: \(loginResponse.refresh_token)")
            print("refres token expires at: \(String(describing: refreshTokenExpiresAt))")
            print("access token: \(loginResponse.access_token)")
            print("access token expires at: \(String(describing: accessTokenExpiresAt))")

            startRefreshTokenExpiryTimer()
            startTokenExpiryTimer()

        } catch {
            serverErrorMessage = "Login request failed: \(error.localizedDescription)"
            print("❌ Login request failed: \(error)")
        }
    }

    // MARK: - Renew Access Token

    func renewAccessToken() async {
        guard let refreshToken = loadFromKeychain(key: "refresh_token"),
              let url = URL(string: "\(url)/api/apple/renew_access_token") else {
            serverErrorMessage = "No refresh token or invalid URL"
            return
        }
        
        serverErrorMessage = nil

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload = ["refresh_token": refreshToken]
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                serverErrorMessage = "Invalid server response"
                isLoggedIn = false
                return
            }

            if httpResponse.statusCode != 200 {
                if let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data) {
                    serverErrorMessage = serverError.detail
                } else {
                    serverErrorMessage = "Refresh failed with status \(httpResponse.statusCode)"
                }
                isLoggedIn = false
                return
            }

            let result = try JSONDecoder().decode(AccessTokenRenew.self, from: data)

            saveToKeychain(key: "access_token", value: result.access_token)
            accessTokenExpiresAt = result.access_token_expires_at
            isLoggedIn = true
            hasTriggeredRefresh = false

            print("✅ Access token refreshed")
            print("access token: \(result.access_token)")
            print("🕒 New expiry at: \(result.access_token_expires_at)")

            startTokenExpiryTimer()

        } catch {
            serverErrorMessage = "Refresh request failed: \(error.localizedDescription)"
            print("❌ Refresh token request failed: \(error)")
        }
    }
    
    // MARK: - Renew Refresh Token
    
    func renewRefreshToken() async {
        guard let refreshToken = loadFromKeychain(key: "refresh_token"),
              let url = URL(string: "\(url)/api/apple/renew_refresh_token") else {
            serverErrorMessage = "Invalid refresh renewal URL or missing token"
            return
        }
        
        serverErrorMessage = nil

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload = ["refresh_token": refreshToken]
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data) {
                    serverErrorMessage = serverError.detail
                } else {
                    serverErrorMessage = "Failed to renew refresh token"
                }
                isLoggedIn = false
                return
            }

            let result = try JSONDecoder().decode(RefreshTokenRenew.self, from: data)

            saveToKeychain(key: "refresh_token", value: result.refresh_token)
            refreshTokenExpiresAt = result.refresh_token_expires_at
            isLoggedIn = true

            print("✅ Refresh token renewed")
            print("refresh token: \(result.refresh_token)")
            print("🕒 New refresh expiry at: \(result.refresh_token_expires_at)")

            startRefreshTokenExpiryTimer()

        } catch {
            serverErrorMessage = "Renewal request failed: \(error.localizedDescription)"
            print("❌ Renewal failed: \(error)")
        }
    }

    // MARK: - Access Token Timer
    
    @Published var elapsedSeconds: Int = 0
    private var timer: Timer?
    private let warningThreshold: TimeInterval = 5 * 60
    private var hasTriggeredRefresh = false
    private var currentNonce: String?

    func startTokenExpiryTimer() {
        stopTimer()
        elapsedSeconds = 0
        hasTriggeredRefresh = false

        guard let expiryTimestamp = accessTokenExpiresAt else {
            print("⚠️ No access token expiry date set.")
            return
        }

        let expiryDate = Date(timeIntervalSince1970: expiryTimestamp)
        let now = Date()
        let timeUntilExpiry = expiryDate.timeIntervalSince(now)

        guard timeUntilExpiry > 0 else {
            print("⚠️ Access token already expired.")
            Task { await renewAccessToken() }
            return
        }

        print("🔁 Starting timer for access token. Expires in \(Int(timeUntilExpiry)) seconds.")

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in
                self.elapsedSeconds += 1
                let remainingTime = expiryDate.timeIntervalSinceNow

                if remainingTime <= self.warningThreshold, remainingTime > 0 {
                    self.handleWarningThreshold(secondsLeft: Int(remainingTime))
                }

                if remainingTime <= 0 {
                    self.timerDidReachExpiry()
                    self.stopTimer()
                }
            }
        }

        RunLoop.main.add(timer!, forMode: .common)
    }

    private func handleWarningThreshold(secondsLeft: Int) {
        guard !hasTriggeredRefresh else { return }
        hasTriggeredRefresh = true
        print("⚠️ Access token expires in \(secondsLeft) seconds. Triggering early refresh...")
        Task { await renewAccessToken() }
    }

    private func timerDidReachExpiry() {
        print("⏰ Access token expired. Triggering refresh or re-login.")
        Task {
            await renewAccessToken()
            startTokenExpiryTimer()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Refresh Token Timer

    @Published var refreshElapsedSeconds: Int = 0

    private var refreshTimer: Timer?
    private let refreshWarningThreshold: TimeInterval = 5 * 60
    private var refreshHasTriggeredRenew = false

    func startRefreshTokenExpiryTimer() {
        stopRefreshTimer()
        refreshElapsedSeconds = 0
        refreshHasTriggeredRenew = false

        guard let expiryTimestamp = refreshTokenExpiresAt else {
            print("⚠️ No refresh token expiry date set.")
            return
        }

        let expiryDate = Date(timeIntervalSince1970: expiryTimestamp)
        let now = Date()
        let timeUntilExpiry = expiryDate.timeIntervalSince(now)

        guard timeUntilExpiry > 0 else {
            print("⚠️ Refresh token already expired.")
            Task { await renewRefreshToken() }
            return
        }

        print("🔁 Starting timer for refresh token. Expires in \(Int(timeUntilExpiry)) seconds.")

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in
                self.refreshElapsedSeconds += 1
                let remainingTime = expiryDate.timeIntervalSinceNow

                if remainingTime <= self.refreshWarningThreshold, remainingTime > 0 {
                    self.handleRefreshWarningThreshold(secondsLeft: Int(remainingTime))
                }

                if remainingTime <= 0 {
                    self.refreshTimerDidReachExpiry()
                    self.stopRefreshTimer()
                }
            }
        }

        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    private func handleRefreshWarningThreshold(secondsLeft: Int) {
        guard !refreshHasTriggeredRenew else { return }
        refreshHasTriggeredRenew = true
        print("⚠️ Refresh token expires in \(secondsLeft) seconds. Triggering early renewal...")
        Task { await renewRefreshToken() }
    }

    private func refreshTimerDidReachExpiry() {
        print("⏰ Refresh token expired. Triggering renewal.")
        Task {
            await renewRefreshToken()
            startRefreshTokenExpiryTimer()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    // MARK: - Sign out
    
    func signOut() {
        print("🚪 Signing out user...")

        deleteFromKeychain(key: "refresh_token")
        deleteFromKeychain(key: "access_token")

        isLoggedIn = false
        accessTokenExpiresAt = nil
        refreshTokenExpiresAt = nil

        stopTimer()
        stopRefreshTimer()

        serverErrorMessage = nil

        print("✅ User signed out and tokens cleared.")
    }
    
    // MARK: - Utility for Apple Sign In

    private func randomNonceString(length: Int = 32) -> String {
        let charset: Array<Character> = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            let randomBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
            for byte in randomBytes where remainingLength > 0 && byte < charset.count {
                result.append(charset[Int(byte)])
                remainingLength -= 1
            }
        }

        return result
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain

    func saveToKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        if let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
    
    func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

}



