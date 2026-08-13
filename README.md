# Auto Firefox for SAP Cloud Foundry

## 🚀 体验地址

- 🌎 **美区 Firefox**  
  👉 [https://firefox.cfapps.us10-001.hana.ondemand.com](https://firefox.cfapps.us10-001.hana.ondemand.com/vnc.html)

> 此文档将说明如何使用随仓库提供的 GitHub Actions 工作流将 **Firefox（含 VNC）Docker 镜像** 部署到 SAP BTP（Cloud Foundry）。

---

## 功能简介
- 通过 GitHub Actions 一键部署到 Cloud Foundry（支持 `SG` / `US` 区域）。
- 可选择部署环境：`staging` / `production`。
- 应用名可自动生成或手动指定。
- 自动从仓库根目录 `.env` 文件注入环境变量。
- 部署完成后自动 `cf app` 验证应用状态。

---

## 如何运行（在 GitHub 界面）
1. 打开仓库页面 → **Actions** → 选择 `自动部署 SAP` 工作流。  
2. 点击 **Run workflow** 并填写表单：
   - `environment`：`staging` 或 `production`  
   - `region`：`SG`（新加坡）或 `US`（美国）  
   - `app_name`（可选）：留空则自动生成（如 `sgxxxxx` 或 `usxxxxx`）

---

## 必需的 GitHub Secrets

在仓库：**Settings → Secrets and variables → Actions** 中新增以下 Secrets：

- `EMAIL` — SAP Cloud Foundry 登录邮箱  
- `PASSWORD` — SAP Cloud Foundry 登录密码  
- `SG_ORG` — 新加坡组织名称  
- `US_ORG` — 美国组织名称  
- `SPACE` — Cloud Foundry 空间名称  
- `VNC_PASSWORD` — VNC 登录密码（**强烈建议设置，避免默认空密码**）

> 注意：工作流中会根据 `region` 选择对应组织（`SG_ORG` 或 `US_ORG`还有`更多`）。

---

由于项目变量太多就不一一列举，大家相互学习交流。
  


# 常见问题（FAQ）  

- **Q：我如何访问 VNC / Firefox？**  
  **A**：点开运行的 **Actions**，点击 **Deploy application**，找到日志中的 `routes:`，后面跟随的域名即为访问地址。  

- **Q：VNC 密码为空会怎样？**  
  **A**：仓库中默认会将 `VNC_PASSWORD` 设置为默认密码（不安全）。强烈建议通过 Secret 提供强密码。  

---

## ♻️ 保活说明

- **最科学的 `keep.sh` 脚本**  
  
```bash
curl -fsSL https://raw.githubusercontent.com/eooce/Auto-deploy-sap-and-keepalive/main/keep.sh -o keep.sh && chmod +x keep.sh

```

使用方法：ssh进vps 一键命令下载运行，修改keep.sh其中的变量，保存即可
---



注意事项
	•	由于 SAP 平台存在的未知安全风险，使用本项目需谨慎账号和数据安全问题，尤其还同时使用F大佬项目的童鞋
	

本项目仅为个人面向 GPT 瞎折腾后，引来一众大佬开动机器测试和默默奉献代码的产物，用于学习交流，禁止用于一切商业行为。

	


## 致谢与学习

- 感谢:[eooce-SAP-Auto](https://github.com/eooce/Auto-deploy-sap-and-keepalive)  自动化 CLI 部署带来的便利

- 学习资料：

- [F佬-ArgoNezha](https://github.com/fscarmen2/Argo-Nezha-Service-Container)  — 无服务器哪吒面板缔造者

- [jlesage/docker-firefox](https://github.com/jlesage/docker-firefox)          — 小型化打包镜像作者

- [linuxserver/docker-firefox](https://github.com/linuxserver/docker-firefox)  — UI页面设计很舒服的镜像

---

春风若有怜花意，人不轻狂枉少年。  

待到那年春暖花开时，再回首，暮然回首那人却在灯火阑珊处。
  
—— 2025/09/25  

6  
1  
3  
3  
3  

愿：人人都有个便携式火狐浏览器。  

---

## ⚖️ 免责声明

所有代码来源于 GitHub 社区，并通过 ChatGPT 进行整合，仅用于学习交流。  

END....

# 📂 SAP-Auto-deploy-Firefox

© 2025 [pingmike2]  

---


## 📜 许可协议

本项目遵循 **知识共享署名-非商业性使用-相同方式共享 4.0 国际许可协议（CC BY-NC-SA 4.0）**。  

你可以：  
- **分享** — 复制、传播本项目内容至任何媒介或形式  
- **改编** — Remix、改造或基于本项目内容进行再创作  
**仅限非商业用途。**  

### 条款说明
- **署名** — 必须为原作者署名，并提供许可协议链接，说明是否修改过。不得以任何方式暗示原作者认可你的使用。  
- **非商业性使用** — 不得将本项目用于商业用途。  
- **相同方式共享** — 如果你对本项目进行改编或再创作，必须在相同许可协议下发布你的贡献。  

**完整许可文本**：[https://creativecommons.org/licenses/by-nc-sa/4.0/](https://creativecommons.org/licenses/by-nc-sa/4.0/)

---

## ⚖️ 免责声明

本项目按 **“原样”** 提供，不提供任何形式的明示或暗示担保，包括但不限于适销性、特定用途适用性及非侵权等。  

使用风险自负，作者不对因使用本项目造成的数据丢失或损害负责。  

---

## 🎨 设计声明

- 本仓库及所有关联内容（脚本、配置、文档）仅用于 **教育和个人学习**。  
- 排版、命名规范、工作流结构均为作者原创。  
- 鼓励在 **CC BY-NC-SA 4.0** 协议下进行二次创作，但 **禁止商业用途**。  

---

## 📌 致谢

- 感谢开源社区提供的示例、脚本与指导。  
- 感谢所有贡献者默默奉献的代码和经验。  

---

**愿大家使用愉快，学习分享，谨慎应用。**
