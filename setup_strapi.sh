#!/bin/bash

# Accept variables as arguments
KHALIL_PASS=$1
GITHUB_TOKEN=$2
DROPLET_NAME=$3
VPC_IP=$4
NODE_VERSION="20.5.0"

# Check if all required arguments are passed
if [ -z "$KHALIL_PASS" ] || [ -z "$GITHUB_TOKEN" ] || [ -z "$DROPLET_NAME" ] || [ -z "$VPC_IP" ]; then
    echo "Usage: $0 <KHALIL_PASS> <GITHUB_TOKEN> <DROPLET_NAME> <VPC_IP>"
    exit 1
fi

# Update the system
sudo apt-get update && sudo apt-get upgrade -y

# Step 1: Install Git & GitHub CLI
echo "Installing Git and GitHub CLI..."
sudo apt install git -y
git --version

# Step 2: Clone the Strapi repository
echo "Cloning Strapi repository..."
mkdir -p /root/$DROPLET_NAME
REPO_URL="https://khalildaibes:$GITHUB_TOKEN@github.com/khalildaibes/ecommerce-strapi.git"
git clone $REPO_URL /root/ecommerce-strapi

# Step 3: Install PostgreSQL
echo "Installing PostgreSQL..."
sudo apt install postgresql postgresql-contrib -y

# Step 4: Configure PostgreSQL
echo "Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE USER strapi WITH PASSWORD '$KHALIL_PASS';"
sudo -u postgres psql -c "ALTER USER strapi WITH SUPERUSER;"
sudo -u postgres psql -c "CREATE DATABASE ecommerce_strapi OWNER strapi;"

# Step 5: Install Node.js and NPM
echo "Installing Node.js and NPM..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
cd /root/ecommerce-strapi/maisam-makeup-ecommerce-strapi/
nvm install $NODE_VERSION
sudo apt-get install -y npm
nvm use $NODE_VERSION
npm install -g npm
npm ci

# Step 6: Start PostgreSQL service
echo "Starting PostgreSQL service..."
sudo systemctl start postgresql

# Step 7: Install Strapi globally
echo "Installing Strapi globally..."
npm install strapi -g

# Step 8: Install PM2
echo "Installing PM2..."
npm install pm2 -g

# Step 9: Install and configure Nginx
echo "Installing and configuring Nginx..."
sudo apt install nginx -y

# Create Nginx configuration file
NGINX_CONFIG="
server {
    listen 80;
    server_name $VPC_IP;

    location / {
        proxy_pass http://localhost:1337;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /api {
        proxy_pass http://localhost:1337;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}"

echo "$NGINX_CONFIG" | sudo tee /etc/nginx/sites-available/website.conf > /dev/null

# Enable the site and test Nginx
sudo ln -s /etc/nginx/sites-available/website.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# Step 10: Configure Strapi .env file
echo "Configuring .env file for Strapi..."
ENV_FILE_CONTENT="
HOST=$VPC_IP
PORT=1337

# Secrets
APP_KEYS=3NuV6u0x3XpEA8lvGouEdg==,SltwwFaxYQsb8xsLpKE4Vw==,IPvlC1iUktw1K0QJhk/U+g==,VvMlfzvlrhe592vSSyzd4g==
API_TOKEN_SALT=IYfKd5TBrKivCGU5kaYqhA==
ADMIN_JWT_SECRET=uO74nAUfjnHjH7Vqhruimw==
TRANSFER_TOKEN_SALT=0wxdTPqLpPPh3vvPfXhrEA==

# Database
DATABASE_CLIENT=postgres
DATABASE_HOST=$VPC_IP
DATABASE_PORT=5432
DATABASE_NAME=ecommerce_strapi
DATABASE_USERNAME=strapi
DATABASE_PASSWORD=$KHALIL_PASS
DATABASE_SSL=false
JWT_SECRET=SLVxTk16zECghjoYsDfrIA=="

echo "$ENV_FILE_CONTENT" | sudo tee /root/ecommerce-strapi/maisam-makeup-ecommerce-strapi/.env > /dev/null

# Step 11: Configure PostgreSQL for external access
echo "Configuring PostgreSQL for external access..."
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/12/main/postgresql.conf
sudo sed -i "/^#.*IPv4 local connections:/a host    ecommerce_strapi    strapi    $VPC_IP/32    md5" /etc/postgresql/12/main/pg_hba.conf
sudo ufw allow 5432/tcp
sudo systemctl restart postgresql

# Step 12: Build and start Strapi
echo "Running the final build and starting Strapi..."
cd /root/ecommerce-strapi/maisam-makeup-ecommerce-strapi
npm ci
npm run build
pm2 start npm --name 'strapi-app' -- run start

# Step 13: Restart PM2
pm2 restart all

echo "Strapi setup complete!"
