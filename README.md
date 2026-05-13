# AMIMOTO AMI for Amazon Linux 2023

AWS Marketplace 向け AMIMOTO WordPress AMI (AL2023 版)

## 構成

```
amimoto-ami2023/
├── ansible/                    # AMI ビルド用 Ansible
│   ├── site.yml               # メイン playbook
│   ├── inventory/hosts.ini
│   └── roles/amimoto/         # amimoto-ansible ベース（WP 除外）
├── scripts/
│   └── initial.wp-setup.sh    # インスタンス起動時スクリプト
└── README.md
```

## AMI に含まれるもの

- nginx (mainline)
- PHP-FPM (SPAL リポジトリ)
- MariaDB
- httpd (Apache)
- memcached / Redis (条件付き)
- monit
- WP-CLI
- phpMyAdmin

## AMI に含まれないもの（起動時にセットアップ）

- WordPress 本体
- wp-config.php / local-config.php
- nginx vhost 設定
- cron 設定

