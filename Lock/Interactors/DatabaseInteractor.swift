// DatabaseInteractor.swift
//
// Copyright (c) 2016 Auth0 (http://auth0.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import Auth0

struct DatabaseInteractor: DatabaseAuthenticatable {

    private var user: DatabaseUser

    var identifier: String? {
        guard self.validEmail || self.validUsername else { return nil }
        return self.validEmail ? self.email : self.username
    }
    var email: String? { return self.user.email }
    var username: String? { return self.user.username }
    var password: String? { return self.user.password }

    var validEmail: Bool { return self.user.validEmail }
    var validUsername: Bool { return self.user.validUsername }
    var validPassword: Bool { return self.user.validPassword }

    let authentication: Authentication
    let connections: Connections
    let emailValidator: InputValidator = EmailValidator()
    let usernameValidator: InputValidator = UsernameValidator()
    let passwordValidator: InputValidator = NonEmptyValidator()
    let onAuthentication: Credentials -> ()

    init(connections: Connections, authentication: Authentication, user: DatabaseUser, callback: Credentials -> ()) {
        self.authentication = authentication
        self.connections = connections
        self.onAuthentication = callback
        self.user = user
    }

    mutating func update(attribute: CredentialAttribute, value: String?) throws {
        let error: ErrorType?
        switch attribute {
        case .Email:
            error = self.updateEmail(value)
        case .Username:
            error = self.updateUsername(value)
        case .Password:
            error = self.updatePassword(value)
        case .EmailOrUsername:
            let emailError = self.updateEmail(value)
            let usernameError = self.updateUsername(value)
            if emailError != nil && usernameError != nil {
                error = emailError
            } else {
                error = nil
            }
        }

        if let error = error { throw error }
    }

    func login(callback: (DatabaseAuthenticatableError?) -> ()) {
        let identifier: String

        if let email = self.email where self.validEmail {
            identifier = email
        } else if let username = self.username where self.validUsername {
            identifier = username
        } else {
            return callback(.NonValidInput)
        }

        guard let password = self.password where self.validPassword else { return callback(.NonValidInput) }
        guard let databaseName = self.connections.database?.name else { return callback(.NoDatabaseConnection) }
        
        self.authentication
            .login(usernameOrEmail: identifier, password: password, connection: databaseName)
            .start { self.handleLoginResult($0, callback: callback) }
    }

    func create(callback: (DatabaseAuthenticatableError?) -> ()) {
        guard let connection = self.connections.database else { return callback(.NoDatabaseConnection) }
        let databaseName = connection.name

        guard
            let email = self.email where self.validEmail,
            let password = self.password where self.validPassword
            else { return callback(.NonValidInput) }

        guard !connection.requiresUsername || self.validUsername else { return callback(.NonValidInput) }

        let username = connection.requiresUsername ? self.username : nil

        let authentication = self.authentication
        let login = authentication.login(usernameOrEmail: email, password: password, connection: databaseName)
        authentication
            .createUser(email: email, username: username, password: password, connection: databaseName)
            .start {
                switch $0 {
                case .Success:
                    login.start { self.handleLoginResult($0, callback: callback) }
                case .Failure:
                    callback(.CouldNotCreateUser)
                }
            }
    }

    private mutating func updateEmail(value: String?) -> InputValidationError? {
        self.user.email = value?.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceAndNewlineCharacterSet())
        let error = self.emailValidator.validate(value)
        self.user.validEmail = error == nil
        return error
    }

    private mutating func updateUsername(value: String?) -> InputValidationError? {
        self.user.username = value?.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceAndNewlineCharacterSet())
        let error = self.usernameValidator.validate(value)
        self.user.validUsername = error == nil
        return error
    }

    private mutating func updatePassword(value: String?) -> InputValidationError? {
        self.user.password = value
        let error = self.passwordValidator.validate(value)
        self.user.validPassword = error == nil
        return error
    }

    private func handleLoginResult(result: Auth0.Result<Credentials>, callback: DatabaseAuthenticatableError? -> ()) {
        switch result {
        case .Failure(let cause as AuthenticationError) where cause.isMultifactorRequired || cause.isMultifactorEnrollRequired:
            callback(.MultifactorRequired)
        case .Failure:
            callback(.CouldNotLogin)
        case .Success(let credentials):
            callback(nil)
            self.onAuthentication(credentials)
        }
    }
}