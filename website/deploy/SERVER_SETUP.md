# Server setup (one time)

Run as root (or with sudo) on the server. `SITE_DOMAIN` is the chosen subdomain.

1. Create a DNS A record (and AAAA if the server has IPv6) for `SITE_DOMAIN` pointing at the server. Wait until it resolves.
2. Create the web root, writable by the user that deploys over rsync:
   ```sh
   mkdir /var/www/cirrus-photos
   chown DEPLOY_USER: /var/www/cirrus-photos
   ```
3. Copy `nginx-cirrus-photos.conf` to `/etc/nginx/sites-available/cirrus-photos`, replace `SITE_DOMAIN` in it, and enable it:
   ```sh
   ln -s /etc/nginx/sites-available/cirrus-photos /etc/nginx/sites-enabled/cirrus-photos
   ```
4. Test the configuration and reload nginx:
   ```sh
   nginx -t && systemctl reload nginx
   ```
5. Obtain the certificate. certbot adds the HTTPS server block and the redirect:
   ```sh
   certbot --nginx -d SITE_DOMAIN
   ```

Deploys only rsync into `/var/www/cirrus-photos` and never touch the nginx configuration.
