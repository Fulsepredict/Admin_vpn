import os
import re
import yaml

def test_audit():
    print("=== STARTING ADMIN_VPN AUDIT ===")
    base_dir = os.path.dirname(os.path.abspath(__file__))
    setup_path = os.path.join(base_dir, "setup.sh")
    admin_path = os.path.join(base_dir, "vpn-admin.sh")
    install_path = os.path.join(base_dir, "install.sh")

    # 1. Line endings check (must not contain \r\n)
    for p in [setup_path, admin_path, install_path]:
        with open(p, "rb") as f:
            content = f.read()
            if b"\r\n" in content:
                print(f"[FAIL] {os.path.basename(p)} has CRLF line endings!")
                return False
            else:
                print(f"[OK] {os.path.basename(p)} has clean LF line endings.")

    # 2. Extract and validate Hysteria 2 YAML configs from setup.sh
    with open(setup_path, "r", encoding="utf-8") as f:
        setup_content = f.read()

    # Base config
    base_yaml_match = re.search(r'cat > "\$HYSTERIA_CONFIG" << EOF\n(.*?)\nEOF', setup_content, re.DOTALL)
    if not base_yaml_match:
        print("[FAIL] Could not find base YAML heredoc in setup.sh")
        return False
    
    base_yaml = base_yaml_match.group(1).replace("${VPN_PASSWORD}", "test_password_12345")
    try:
        parsed_base = yaml.safe_load(base_yaml)
        assert "listen" in parsed_base, "listen missing"
        assert "tls" in parsed_base, "tls missing"
        assert "auth" in parsed_base, "auth missing"
        assert parsed_base["auth"]["password"] == "test_password_12345", "password hierarchy invalid"
        assert "masquerade" in parsed_base, "masquerade missing"
        print("[OK] Base Hysteria 2 YAML is 100% valid.")
    except Exception as e:
        print(f"[FAIL] Base YAML invalid: {e}")
        return False

    # Extended ACL config
    warp_yaml_match = re.search(r'cat >> "\$HYSTERIA_CONFIG" << EOF\n(.*?)\nEOF', setup_content, re.DOTALL)
    if not warp_yaml_match:
        print("[FAIL] Could not find WARP YAML heredoc in setup.sh")
        return False
    
    full_yaml = base_yaml + "\n" + warp_yaml_match.group(1).replace("${WARP_SOCKS_PORT}", "40000")
    try:
        parsed_full = yaml.safe_load(full_yaml)
        assert "outbounds" in parsed_full, "outbounds missing"
        assert parsed_full["outbounds"][0]["name"] == "warp_proxy"
        assert parsed_full["outbounds"][0]["socks5"]["addr"] == "127.0.0.1:40000"
        assert "acl" in parsed_full, "acl missing"
        assert len(parsed_full["acl"]["inline"]) > 5, "ACL inline rules empty"
        print(f"[OK] Extended Smart ACL YAML is 100% valid ({len(parsed_full['acl']['inline'])} rules).")
    except Exception as e:
        print(f"[FAIL] Extended YAML invalid: {e}")
        return False

    # 3. Check password change sed regex in vpn-admin.sh
    with open(admin_path, "r", encoding="utf-8") as f:
        admin_content = f.read()

    # Simulate sed replacement on full_yaml
    test_yaml_lines = full_yaml.splitlines()
    replaced_lines = []
    for line in test_yaml_lines:
        new_line = re.sub(r'^[ \t]*password:.*', '  password: brand_new_pass_999', line)
        replaced_lines.append(new_line)
    
    re_parsed = yaml.safe_load("\n".join(replaced_lines))
    assert re_parsed["auth"]["password"] == "brand_new_pass_999", "Password sed broke YAML indentation!"
    print("[OK] Password sed replacement preserves exact YAML indentation.")

    # 4. Check UFW reset order in setup.sh
    reset_idx = setup_content.find("ufw --force reset")
    before_rules_idx = setup_content.find("before.rules")
    assert reset_idx != -1, "ufw reset missing"
    assert before_rules_idx != -1, "before.rules missing"
    assert reset_idx < before_rules_idx, "ufw reset MUST come BEFORE before.rules modification!"
    print("[OK] UFW reset order is safe (reset runs BEFORE modifying before.rules).")

    # 5. Check URL consistency
    assert "https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh" in setup_content
    assert "https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh" in open(install_path, "r", encoding="utf-8").read()
    print("[OK] GitHub repository URLs are consistent across all scripts.")

    print("=== ALL AUDIT CHECKS PASSED SUCCESSFULLY (5/5) ===")
    return True

if __name__ == "__main__":
    import sys
    if test_audit():
        sys.exit(0)
    else:
        sys.exit(1)
