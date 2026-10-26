# AMI ビルド手順（AMIMOTO AMI for Amazon Linux 2023）

AL2023 インスタンスを立て、本リポジトリで構成 → AMI を作成する手順。

> **重要な2点（新規起動の 403/502 を防ぐため必須）**
> 1. ansible 実行時に **`-e amimoto_config_force=true`** を付ける
>    → 焼き込み時にロールの正しい設定を適用する（特に `www.conf` の php-fpm ソケット所有者 `amimoto-user:www`）。
>    これが無いと、ディストリ既定の `www.conf`（`listen.acl_users = apache,nginx`）が残り、起動後に全 PHP リクエストが **502**（socket permission denied）になる。
> 2. クリーンアップで **`default.conf` / `default.backend.conf` を削除**してから AMI 化する
>    → これらは **インスタンスごとに docroot が変わる**ため焼き込まない。削除しておけば、起動時に各インスタンスの正しい docroot で生成される（`force:no` の「無ければ作る」）。
>    残したまま焼くと、ビルド機の docroot（`/var/www/vhosts/localhost`）を指したまま固定され **403** になる。

## 1. EC2 インスタンス作成
- AMI: Amazon Linux 2023
- インスタンスタイプ: 任意（例 t3.small）
- ストレージ: gp3 / 30GB 以上

## 2. Ansible を実行

```bash
sudo su -
dnf -y install ansible-core git

git clone https://github.com/Launch-with-1-Click/lw1-amimoto2023.git /opt/local/ansible
cd /opt/local/ansible

ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml \
  -e "amimoto_ec2_region=ap-northeast-1" \
  -e "amimoto_config_force=true"            # ← 焼き込み時は必ず付ける
```

## 3. initial.wp-setup.sh を配置

```bash
cp scripts/initial.wp-setup.sh /opt/local/initial.wp-setup.sh
chmod +x /opt/local/initial.wp-setup.sh
```

## 4. 初回起動スクリプトを cloud-init に登録

```bash
vi /etc/cloud/cloud.cfg.d/wp-setup.cfg
```

```yaml
#cloud-config
runcmd:
- /bin/bash /opt/local/initial.wp-setup.sh
- echo "実行完了" >> /tmp/status.log
```

## 5. クリーンアップして AMI 作成

```bash
# per-instance の既定サイト設定は焼き込まない（起動時に各機体のdocrootで生成させる）
rm -f /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.backend.conf

# 履歴・ログの削除
rm -f /root/.bash_history /home/ec2-user/.bash_history
rm -rf /var/log/nginx/* /var/log/php-fpm/* /var/cache/nginx/*
rm -f /var/log/cloud-init*.log
# 認証キーも必要に応じて削除
# vi /home/ec2-user/.ssh/authorized_keys
# vi /root/.ssh/authorized_keys
history -c
```

この状態で EC2 コンソール等から AMI を作成する。

## 焼き上がった AMI の挙動
- **www.conf**: 正しい（`amimoto-user:www` / 0666）→ 502 なし
- **default.conf / default.backend.conf**: 焼き込まれない → 初回起動時に各インスタンスの docroot で生成 → 403 なし
- **reboot 時**: `/opt/local/provision` は `amimoto_config_force` を渡さない → `force:no` のまま → 手動設定を保持（EFS 共有の既定設定も上書きしない）

## 補足
- `amimoto_config_force` は既定 `false`（= `force:no`）。**焼き込み時のみ** `true` を渡す運用。
- インスタンス固有の設定（PHP バージョン・docroot 等）は `/opt/local/amimoto.json` で管理できる（README 参照）。
