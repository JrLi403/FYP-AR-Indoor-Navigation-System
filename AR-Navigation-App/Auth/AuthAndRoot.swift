import ActivityKit
import SwiftUI
import ARKit
import SceneKit
import simd
import Combine
import AVFoundation
import UniformTypeIdentifiers
import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
// MARK: - 登录 & 权限

enum UserRole { case manager, viewer }

final class AuthViewModel: ObservableObject {
    @Published var user: User?
    @Published var role: UserRole?
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    init() {
        self.user = Auth.auth().currentUser
        if let u = user { detectRole(for: u) }
    }

    func login(email: String, password: String) {
        errorMessage = nil
        Auth.auth().signIn(withEmail: email, password: password) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.errorMessage = error.localizedDescription
                    return
                }
                guard let user = result?.user else { return }
                self?.user = user
                self?.detectRole(for: user)
            }
        }
    }

    private func detectRole(for user: User) {
        let uid = user.uid
        db.collection("managers").document(uid).getDocument { [weak self] snap, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.errorMessage = "Failed to detect role: \(error.localizedDescription)"
                    self?.role = .viewer
                    return
                }
                self?.role = (snap?.exists == true) ? .manager : .viewer
            }
        }
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            DispatchQueue.main.async {
                self.user = nil
                self.role = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// 登录界面
struct LoginView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var email: String = ""
    @State private var password: String = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("Login").font(.largeTitle).bold()

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(white: 0.15))
                    .cornerRadius(8)
                    .foregroundColor(.white)

                SecureField("Password", text: $password)
                    .padding(10)
                    .background(Color(white: 0.15))
                    .cornerRadius(8)
                    .foregroundColor(.white)
            }

            Button { authVM.login(email: email, password: password) } label: {
                Text("Login")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }

            if let err = authVM.errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
    }
}

// 根视图
struct RootView: View {
    @EnvironmentObject var authVM: AuthViewModel
    var body: some View {
        if authVM.user == nil { LoginView() }
        else { ARNavigationHomeView().environmentObject(authVM) }
    }
}
