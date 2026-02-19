#!/bin/bash
set -e

# Run the Ansible playbook
if [ "$EUID" -eq 0 ]; then
    ansible-playbook playbook.yml -e ansible_become=false "$@"
    PLAYBOOK_EXIT=$?
else
    ansible-playbook playbook.yml --ask-become-pass "$@"
    PLAYBOOK_EXIT=$?
fi

# After playbook completes successfully, show instructions
if [ $PLAYBOOK_EXIT -eq 0 ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "✅ INSTALLATION COMPLETE!"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "🔄 NEXT STEPS (macOS):"
        echo ""
        echo "  Open a new terminal window (to reload .zshrc), then run:"
        echo ""
        echo "    openclaw onboard --install-daemon"
        echo ""
        echo "  This will guide you through the setup wizard."
    else
        echo "🔄 SWITCH TO OPENCLAW USER with:"
        echo ""
        echo "    sudo su - openclaw"
        echo ""
        echo "  OR (alternative):"
        echo ""
        echo "    sudo -u openclaw -i"
        echo ""
        echo "  This will switch you to the openclaw user with a proper"
        echo "  login shell (loads .bashrc, sets environment correctly)."
    fi
    echo ""
    echo "After switching, you'll see the next setup steps:"
    echo "  • Configure OpenClaw (~/.openclaw/config.yml)"
    echo "  • Login to messaging provider (WhatsApp/Telegram/Signal)"
    echo "  • Test the gateway"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo ""
else
    echo "❌ Playbook failed with exit code $PLAYBOOK_EXIT"
    exit $PLAYBOOK_EXIT
fi
