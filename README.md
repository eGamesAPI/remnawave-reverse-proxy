<p aling="center"><a href="https://github.com/eGamesAPI/remnawave-reverse-proxy">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="./media/logo.png" />
   <source media="(prefers-color-scheme: light)" srcset="./media/logo-black.png" />
   <img alt="Remnawave Reverse Proxy" src="https://github.com/eGamesAPI/remnawave-reverse-proxy" />
 </picture>
</a></p>

English | [Русский](/README-RU.md)

> [!CAUTION]
> **THIS REPOSITORY IS AN EDUCATIONAL EXAMPLE FOR LEARNING NGINX, REVERSE PROXY AND NETWORK SECURITY BASICS. THIS SCRIPT DEMONSTRATES NGINX CONFIGURATION AS A REVERSE PROXY. NOT FOR PROD AND NOT FOR PRODUCTION USE! IF YOU DON'T UNDERSTAND HOW THE CONTROL PANEL WORKS - THAT'S YOUR PROBLEM, NOT THE SCRIPT AUTHOR'S. USE AT YOUR OWN RISK!**

### Server Using NGINX Reverse Proxy
This script is designed to streamline the setup of a reverse proxy server using NGINX and Xray, as well as to automate the installation of the Remnawave control panel and node. In this configuration, Xray operates directly on port 443, forwarding traffic through a socket that NGINX listens to. This approach minimizes unnecessary TCP overhead, delivering improved performance and connection reliability.
> [!IMPORTANT]
> Supports Debian and Ubuntu. The script has been tested in a KVM virtualization environment. For proper operation, you will need your own domain. It is recommended to run it with root privileges on a freshly installed system.

The script supports deployment on either a single server (with both the panel and node together) or two separate servers, depending on your needs:

- Single Server: Ideal for a compact setup where the control panel and Xray node are installed on the same machine.
- Panel Server: Serves as the central management hub, without hosting an Xray node.
- Node Server: Hosts the Xray node along with a Self Steal stub for VLESS REALITY.
To ensure proper operation, you need to prepare three domains (or subdomains) in advance: the first will be used for the control panel, the second for handling subscriptions, and the third for the Self Steal stub site, which is hosted on the node server.

-----

### Domain Configuration
The script supports two methods of domain configuration: via Cloudflare or using ACME with your hosting provider.

### DNS Records Setup for Panel + Node on the Same Server

| Type  | Name              | Content          | Proxy status  |
| ----- | ----------------- | ---------------- | ------------- |
| A     | example.com       | your_server_ip   | DNS only      |
| CNAME | panel.example.com | example.com      | DNS only      |
| CNAME | sub.example.com   | example.com      | DNS only      |
| CNAME | node.example.com  | example.com      | DNS only      |

> [!TIP]
> The node.example.com record is not mandatory for a selfsteal node — you can also use example.com for selfsteal.

### DNS Records Setup for Panel and Node on Separate Servers

| Type  | Name              | Content                 | Proxy status  |
| ----- | ----------------- | ----------------------- | ------------- |
| A     | example.com       | your_server_ip          | DNS only      |
| CNAME | panel.example.com | example.com             | DNS only      |
| CNAME | sub.example.com   | example.com             | DNS only      |
| A     | node.example.com  | your_server_ip_vps_node | DNS only      |

-----

### Installation Guidelines
### 1. Single Server Setup:
   - Select the option "Install Remnawave components", then choose "Install panel and node on one server". Once the process is complete, the script will automatically restart the panel and provide all the necessary login details.
### 2. Dual Server Setup
   - Start with the first server and select the option "Install Remnawave components," then choose "Install panel only." Wait for the script to complete the setup and provide the login details for the panel.
   - Log into the control panel, navigate to Nodes → Management, select the desired node, and click the "Important Information". In the pop-up window, you’ll see an icon to copy the certificate — click on it.
   - Proceed to the second server and initiate the node installation. When prompted, paste the certificate you copied earlier.
   - Upon completion, you’ll see a message confirming that the node has been successfully connected.

-----

### Panel Protection via URL Parameter
To enhance the security of the panel, an additional layer of protection against detection has been implemented in the NGINX configuration:
- To access the panel, you must navigate to a URL in the following format:
  ```
  https://panel.example.com/auth/login?<SECRET_KEY>=<SECRET_KEY>
  ```
- This request automatically sets a special Cookie in the browser with the name <SECRET_KEY> and the value <SECRET_KEY>.
- If the Cookie is missing or the URL request lacks the specified parameter, the user will encounter either a blank page or a 404 error, depending on the requested path.

This mechanism ensures the panel remains hidden from unauthorized access. Even if an attacker attempts to scan the host or brute-force paths, they will be unable to access the panel without the correct parameter and corresponding Cookie.

-----

### Proxy server configuration:
1. Proxy server configuration:
   - Support for automatic configuration updates via subscription and JSON subscription with the ability to convert to formats for popular applications.
2. NGINX reverse proxy setup in combination with Xray.
3. Security measures:
   - UFW setup for access management.
   - Cloudflare/ACME SSL certificates with automatic renewal
   - Manage IPv6 to prevent potential vulnerabilities.
   - BBR optimization for TCP connections.
   - Selecting a random website template from an array.

-----

### Server Setup:

To set up the server, run this command on it:

For the latest version of Remnawave
```
bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh)
```
<p align="center"><a href="#"><img src="./media/remnawave-reverse-proxy_en.png" alt="Image"></a></p>

-----

> [!IMPORTANT]
> **This repository is intended solely for educational purposes and for studying the principles of reverse proxy servers and network security. The script demonstrates the setup of a proxy server using NGINX for reverse proxy, traffic management, and attack protection.**
>
>**We strongly remind you that using this tool to bypass network restrictions or censorship is illegal in certain countries that have laws regulating the use of technologies to circumvent internet restrictions.**
>
>**This project is not intended for use in ways that violate information protection laws or interfere with censorship mechanisms. We take no responsibility for any legal consequences arising from the use of this script.**
>
>**Use this tool/script only for demonstration purposes, as an example of reverse proxy operation and data protection. We strongly recommend removing the script after reviewing it. Further use is at your own risk.**
>
>**If you are unsure whether the use of this tool or its components violates the laws of your country, refrain from interacting with this tool.**

## Telegram chat

Join our [Telegram chat](https://t.me/remnawave_reverse) to ask questions and discuss the project with other users.

## Donations

If you enjoy this project and want to support its ongoing development, please consider making a donation. Your contribution helps fund future updates and enhancements!

**Donation Methods:**

- **TON USDT:** `UQAxyZDwKUPQ5Bp09JOFcaDVakjYQT46rf3iP3lnl_qc9xVS`
