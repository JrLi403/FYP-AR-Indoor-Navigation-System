# Indoor AR Navigation System (iOS)

[English](#english) | [中文](#中文)

---

## English

### Overview
This project implements a **smartphone-based indoor navigation system** using Augmented Reality (AR) and motion sensing. It is designed for structured indoor environments such as university buildings, where traditional GPS-based navigation fails.

Unlike infrastructure-based solutions (e.g., Bluetooth beacons or Wi-Fi fingerprinting), this system adopts a **trace-based navigation approach**, where routes are recorded once and reused for future navigation.

---

### Demo Video
https://fyp-indoor-navigation.blogspot.com/2026/03/video.html

---

### System Architecture

The system consists of two independent iOS applications:

#### 1. AR Navigation App
- End-user navigation interface
- QR code-based starting point initialization
- AR-based visual navigation guidance
- Real-time motion tracking using sensors

#### 2. Route Recording & Database App
- Admin-only application
- Route recording using motion sensors
- Upload route data to Firebase Firestore
- Manage nodes and room mappings

---

### Key Features
- No external infrastructure required
- Motion-based trajectory reconstruction
- Graph-based indoor navigation model
- Reusable recorded routes
- Firebase cloud database integration
- Role-based access control (Admin/User)
- QR code initialization
- AR visual guidance

---

### Technical Highlights

- **CoreMotion**: Used for yaw estimation and step detection  
- **ARKit**: Provides real-time spatial tracking and visual guidance  
- **Firebase Firestore**: Stores routes, nodes, and room data  
- **Graph Model**: Indoor space represented as nodes and edges  

---

### Project Structure

```
/AR-Navigation-App
    /App
    /Views
    /Navigation
    /Models
    /Firestore

/Record-Route-Database-App
    /App
    /Views
    /Recording
    /Database
```

---

### Setup Instructions

#### Requirements
- Xcode (latest version recommended)
- iOS device (ARKit supported)
- Firebase account

#### Steps
1. Clone the repository  
2. Open the project in Xcode  
3. Add your own `GoogleService-Info.plist`  
4. Enable required permissions:
   - Camera
   - Motion
   - ARKit
5. Run the app on a real device  

---

### Notes
- `GoogleService-Info.plist` is NOT included
- Must be configured separately
- Ensure correct target membership in Xcode

---

### Future Work
- Improve motion accuracy and reduce drift
- Support multi-floor navigation
- Cross-platform expansion (Android / Web)
- Automated node generation

---

## 中文

### 项目简介
本项目实现了一个基于**智能手机的室内导航系统**，结合增强现实（AR）与运动传感技术，适用于大学教学楼等结构化室内环境。

与依赖蓝牙信标或 Wi-Fi 指纹的传统方案不同，本系统采用**轨迹复用（trace-based）方法**，即路线录制一次后即可重复用于导航。

---

### 演示视频
https://fyp-indoor-navigation.blogspot.com/2026/03/video.html

---

### 系统架构

系统由两个独立的 iOS 应用组成：

#### 1. AR Navigation App（导航端）
- 面向用户的导航界面  
- 二维码初始化起点  
- AR 可视化导航引导  
- 实时运动跟踪  

#### 2. Route Recording & Database App（管理端）
- 仅管理员使用  
- 基于传感器的路径录制  
- 上传数据到 Firebase Firestore  
- 管理节点与房间信息  

---

### 核心功能
- 无需额外基础设施  
- 基于运动的轨迹重建  
- 基于图结构的室内导航模型  
- 路径可复用  
- Firebase 云数据库支持  
- 权限管理（管理员/用户）  
- 二维码初始化  
- AR 导航指引  

---

### 技术要点
- **CoreMotion**：航向角与步态检测  
- **ARKit**：空间定位与 AR 引导  
- **Firebase Firestore**：数据存储  
- **图模型**：节点与路径连接  

---

### 项目结构

```
/AR-Navigation-App
/Record-Route-Database-App
```

---

### 运行说明

#### 环境要求
- Xcode
- 支持 ARKit 的 iOS 设备
- Firebase 账号

#### 步骤
1. 克隆仓库  
2. 使用 Xcode 打开项目  
3. 添加 `GoogleService-Info.plist`  
4. 开启相机 / 运动 / AR 权限  
5. 在真机运行  

---

### 注意事项
- 不包含 Firebase 配置文件  
- 需自行配置  
- 注意 target 绑定  

---

### 后续工作
- 提升精度与减少漂移  
- 支持跨楼层导航  
- 扩展 Android / Web  
- 自动生成节点  
