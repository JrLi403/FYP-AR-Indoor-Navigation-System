# Indoor AR Navigation System (iOS)

## 📌 Overview | 项目简介

This project implements a **smartphone-based indoor navigation system** using AR and motion sensing, designed for structured indoor environments such as university buildings.

本项目实现了一个基于智能手机的**室内导航系统**，结合增强现实（AR）与运动传感，主要面向如大学教学楼等结构化室内环境。

Unlike traditional indoor navigation systems that rely on infrastructure (e.g., Bluetooth beacons or Wi-Fi fingerprinting), this system adopts a **trace-based approach**, allowing routes to be recorded once and reused for navigation.

与依赖蓝牙信标或 Wi-Fi 指纹的传统室内导航不同，本系统采用**轨迹复用（trace-based）方法**，通过一次路线录制即可反复用于导航。

---

## 🎬 Demo Video | 演示视频

Watch the system demo here:  
https://fyp-indoor-navigation.blogspot.com/2026/03/video.html

点击观看系统演示视频：  
https://fyp-indoor-navigation.blogspot.com/2026/03/video.html

---

## 🧩 System Architecture | 系统架构

The project consists of **two independent iOS applications**:

本项目由**两个独立的 iOS 应用组成**：

### 1. AR Navigation App
- End-user navigation interface  
- QR code-based initialization  
- AR-based visual guidance  
- Real-time motion tracking  

用户导航端，包含：
- 二维码初始化定位  
- AR 实时导航指引  
- 运动传感路径重建  

---

### 2. Route Recording & Database App
- Admin-only interface  
- Route recording using sensors  
- Upload data to Firestore  
- Manage nodes and room mapping  

管理员端，包含：
- 路径录制（基于传感器）  
- 上传数据至 Firebase Firestore  
- 节点与房间信息管理  

---

## ⚙️ Key Features | 核心功能

- Smartphone-based navigation (no external hardware)  
- Motion-based trajectory reconstruction  
- Node-based indoor graph representation  
- Reusable recorded routes  
- Cloud-based data storage (Firebase Firestore)  
- Role-based access (Admin vs User)  
- QR code initialization  
- AR visual guidance  

---

## 🏗️ Project Structure | 项目结构

/AR-Navigation-App  
/Record-Route-Database-App  

---

## 🚀 Setup Instructions | 运行说明

### Requirements
- Xcode
- iOS device (ARKit supported)
- Firebase account

### Steps

1. Clone the repository  
2. Open project in Xcode  
3. Add your own `GoogleService-Info.plist`  
4. Enable permissions (Camera, Motion, ARKit)  
5. Run on real device  

---

## ⚠️ Important Notes | 注意事项

- `GoogleService-Info.plist` is NOT included  
- Must be configured manually  
- Ensure correct target membership  

---

## 🔮 Future Work | 后续工作

- Improve motion accuracy (drift reduction)  
- Cross-platform support  
- Multi-floor navigation  
- Automated node generation  

---

## 📄 License | 许可

This project is for academic use only.

本项目仅用于学术用途。
