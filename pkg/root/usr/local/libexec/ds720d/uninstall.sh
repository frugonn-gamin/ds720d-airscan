#!/bin/sh
# Désinstalle le pont AirScan du Brother DS-720D (services, agent, règle sudo).
# Le scanneur redevient un simple disque USB pour macOS.
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
CONSOLE_UID=$(stat -f %u /dev/console)
[ "$CONSOLE_UID" != 0 ] && launchctl bootout "gui/$CONSOLE_UID/local.ds720d.agent" 2>/dev/null
launchctl bootout system/local.ds720d.airscan 2>/dev/null
launchctl bootout system/local.ds720d.usbd 2>/dev/null
pkill -x ds720d-agent 2>/dev/null
pkill -f "local.ds720d.usbd" 2>/dev/null
rm -f /private/etc/sudoers.d/ds720d
rm -f /Library/LaunchAgents/local.ds720d.agent.plist
rm -f /Library/LaunchDaemons/local.ds720d.airscan.plist /Library/LaunchDaemons/local.ds720d.usbd.plist
rm -f /Library/PrivilegedHelperTools/local.ds720d.usbd
rm -f /var/run/ds720d-usbd.sock /var/log/ds720d-usbd.log /var/log/ds720d-airscan.log
rm -rf /usr/local/libexec/ds720d
pkgutil --forget local.ds720d.airscan >/dev/null 2>&1
echo "Pont AirScan DS-720D désinstallé."
echo "Pensez à retirer ds720d-agent de Réglages > Confidentialité et sécurité si vous l'y aviez ajouté."
