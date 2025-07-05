//
//  AppleSignInModel.swift
//  Feel Buddha
//
//  Created by Low Wai Kit on 6/29/25.
//

import Foundation

struct ServerErrorResponse: Codable {
    let detail: String
}

struct AppleLoginPayload: Codable {
    let id_token: String
    let nonce: String
    let user_identifier: String
    let email: String?
    let full_name: String?
}

struct AppleLoginResponse: Codable {
    let user_id: String
    let email: String?
    let username: String?
    let access_token: String
    let refresh_token: String
    let access_token_expires_at: Double
    let refresh_token_expires_at: Double
}

struct AccessTokenRenew: Codable {
    let access_token: String
    let access_token_expires_at: Double
}

struct RefreshTokenRenew: Codable {
    let refresh_token: String
    let refresh_token_expires_at: Double
}
