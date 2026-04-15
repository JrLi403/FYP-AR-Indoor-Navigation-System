//
//  record_route_v3_0App.swift
//  record route v3.0
//
//  Created by JrLee on 17/11/2025.
//

//
//  RecordRouteDatabaseApp.swift
//  record route + Database
//
//  Created by JrLee
//

import SwiftUI
import FirebaseCore

@main
struct RecordRouteDatabaseApp: App {
    // 如果你需要用到 UIApplicationDelegate（比如推送、URL 回调等），
    // 可以保留这个最简单的 AppDelegate。
    @UIApplicationDelegateAdaptor(RecordRouteAppDelegate.self) var appDelegate

    init() {
        // 有些人喜欢在这里再保险一下
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            // 就是你这份带“记录路线 + 管理数据库 + Room_type”的 ContentView
            RecordRouteHomeView()
        }
    }
}

// 如果你项目里还没有 AppDelegate，可以用这个最简版
final class RecordRouteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        // Firebase 只需要 configure 一次，如果已经在别处 configure 了，就别重复
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        return true
    }
}

