# Server setup (one time)

Run as root on the server (`ssh ionos`). The site is `cirrusphotos.richardhanss.de`.

1. Create a DNS A record (and AAAA if the server has IPv6) for `cirrusphotos.richardhanss.de` pointing at the server. Wait until it resolves.
2. Create the web root (deploys rsync into it as root over `ssh ionos`):
   ```sh
   mkdir -p /var/www/cirrus-photos
   ```
3. Copy `nginx-cirrus-photos.conf` to `/etc/nginx/sites-available/cirrus-photos` and enable it:
   ```sh
   ln -s /etc/nginx/sites-available/cirrus-photos /etc/nginx/sites-enabled/cirrus-photos
   ```
4. Test the configuration and reload nginx:
   ```sh
   nginx -t && systemctl reload nginx
   ```
5. Obtain the certificate. certbot adds the HTTPS server block and the redirect:
   ```sh
   certbot --nginx -d cirrusphotos.richardhanss.de
   ```

Deploys only rsync into `/var/www/cirrus-photos` and never touch the nginx configuration.
