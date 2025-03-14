# REMNAWAVE-REVERSE-PROXY ([Russian](/README-RU.md))
### Server Using NGINX Reverse Proxy
This script is designed for quick setup of a reverse proxy server based on NGINX in combination with Xray. In this setup, Xray operates directly on port 443, redirects to a socket, and NGINX listens to it, eliminating unnecessary TCP overhead. This approach enhances connection performance and stability.
> [!IMPORTANT]
> This script has been tested in a KVM virtualization environment. For proper operation, you will need your own domain, which must be linked to Cloudflare. It is recommended to run the script with root privileges on a freshly installed system.
-----
### CLOUDFLARE Configuration
1. Configure Cloudflare:
   - Link your domain to Cloudflare.
   - Add the following DNS records:

| Type  | Name              | Content          | Proxy status  |
| ----- | ----------------- | ---------------- | ------------- |
| A     | example.com       | your_server_ip   | DNS only      |
| CNAME | panel.example.com | example.com      | DNS only      |
| CNAME | sub.example.com   | example.com      | DNS only      |

2. SSL/TLS settings in Cloudflare:
   - Go to SSL/TLS > Overview and select Full for the Configure parameter.
   - Set Minimum TLS Version to TLS 1.3.
   - Enable TLS 1.3 (true) in the Edge Certificates section.
-----
1. Proxy server configuration:
   - Support for automatic configuration updates via subscription and JSON subscription with the ability to convert to formats for popular applications.
2. NGINX reverse proxy setup in combination with Xray.
3. Security measures:
   - Automatic system updates via unattended-upgrades.
   - Configuration of Cloudflare SSL certificates with automatic renewal to secure connections.
   - UFW (Uncomplicated Firewall) setup for access management.
   - Disabling IPv6 to prevent potential vulnerabilities.
   - Encrypting DNS queries using systemd-resolved (DoT)
   - Selecting a random website template from an array.
4. Enabling BBR — improving TCP connection performance.
-----
### Server Setup:

To set up the server, run this command on it:

```
bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh)
```

<p align="center"><a href="#"><img src="./media/remnawave-reverse-proxy.png" alt="Showcase"></a></p>

### Star History

<a href="https://github.com/eGamesAPI/remnawave-reverse-proxy/stargazers">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=eGamesAPI/remnawave-reverse-proxy&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=eGamesAPI/remnawave-reverse-proxy&type=Date" />
   <img alt="Stars" src="https://api.star-history.com/svg?repos=eGamesAPI/remnawave-reverse-proxy&type=Date" />
 </picture>
</a>