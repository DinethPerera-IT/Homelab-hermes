#!/usr/bin/env bash
# usage: ./set-secret.sh VAR_NAME
read -rsp "Value for $1: " V; echo
sed -i "s|^$1=.*|$1=$V|" .env
unset V
echo "$1 set."
