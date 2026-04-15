//
//  AR_Navigation_v3_0App.swift
//  AR Navigation v3.0
//
//  Created by JrLee on 17/11/2025.
//


import SwiftUI
import FirebaseCore        // ✅ 一定要有

@main
struct ARNavigationApp: App {

    // 让 AppDelegate 负责调用 FirebaseApp.configure()
    @UIApplicationDelegateAdaptor(ARNavigationAppDelegate.self) var appDelegate

    @StateObject var authVM = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authVM)
        }
    }
}

// 旧式 AppDelegate，用来做 Firebase 初始化
final class ARNavigationAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {

        FirebaseApp.configure()   // ✅ 在这里初始化 Firebase
        return true
    }
}
