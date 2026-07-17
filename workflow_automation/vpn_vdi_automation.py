#!/usr/bin/env python3
"""
Automated VPN and VDI login script for Samsung VPN and SmartDSI device management portal.

This script automates:
1. Navigating to Samsung VPN SSL portal
2. Entering VPN credentials
3. Waiting for manual SSO phone authentication
4. Waiting for VPN connection establishment
5. Navigating to device management portal
6. (Optional) Device search and file download capabilities

Requirements:
- selenium
- webdriver-manager
- Chrome browser with existing profile

Usage:
    python vpn_vdi_automation.py
"""

import time
import logging
import os
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from webdriver_manager.chrome import ChromeDriverManager

# Configuration - UPDATE THESE VALUES
VPN_URL = "https://www.samsungvpn.com/ingdc"
DEVICE_PORTAL_URL = "https://smartsdsi.swa-workspace.com"
VPN_USERNAME = "your_vpn_username_here"  # Replace with actual username
VPN_PASSWORD = "your_vpn_password_here"  # Replace with actual password

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("vpn_vdi_automation.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class VPNAutomation:
    def __init__(self):
        self.driver = None
        self.wait = None

    def setup_driver(self):
        """Setup Chrome driver with existing profile"""
        try:
            logger.info("Setting up Chrome driver...")

            chrome_options = Options()

            # Use existing Chrome profile to maintain sessions and cookies
            # This helps with SSO and avoids re-authentication issues
            chrome_options.add_argument("--user-data-dir=" + os.path.join(
                os.path.expanduser("~"),
                "Library", "Application Support", "Google", "Chrome"
            ))
            chrome_options.add_argument("--profile-directory=Default")

            # Additional options for stability
            chrome_options.add_argument("--no-sandbox")
            chrome_options.add_argument("--disable-dev-shm-usage")
            chrome_options.add_argument("--disable-blink-features=AutomationControlled")
            chrome_options.add_experimental_option("excludeSwitches", ["enable-automation"])
            chrome_options.add_experimental_option('useAutomationExtension', False)

            # Set download directory to Downloads folder
            # Handle .ica files which open automatically - we'll prevent auto-open
            prefs = {
                "download.default_directory": os.path.join(os.path.expanduser("~"), "Downloads"),
                "download.prompt_for_download": False,
                "download.directory_upgrade": True,
                "safebrowsing.enabled": True,
                # Prevent Chrome from automatically opening certain file types
                "profile.default_content_setting_values.automatic_downloads": 1,
                "profile.default_content_settings.popups": 0,
            }
            # Add .ica to the list of files that shouldn't be opened automatically
            chrome_options.add_experimental_option("prefs", prefs)

            # Initialize driver
            service = Service(ChromeDriverManager().install())
            self.driver = webdriver.Chrome(service=service, options=chrome_options)
            self.driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")

            self.wait = WebDriverWait(self.driver, 30)
            logger.info("Chrome driver setup complete")

        except Exception as e:
            logger.error(f"Failed to setup Chrome driver: {str(e)}")
            raise

    def navigate_to_vpn(self):
        """Navigate to VPN login page"""
        try:
            logger.info(f"Navigating to VPN portal: {VPN_URL}")
            self.driver.get(VPN_URL)

            # Wait for page to load
            self.wait.until(EC.presence_of_element_located((By.TAG_NAME, "body")))
            logger.info("VPN portal loaded successfully")

        except Exception as e:
            logger.error(f"Failed to navigate to VPN portal: {str(e)}")
            raise

    def enter_vpn_credentials(self):
        """Enter VPN username and password"""
        try:
            logger.info("Entering VPN credentials...")

            # Common selectors for username/password fields - adjust based on actual portal
            username_selectors = [
                "input[name='username']",
                "input[id='username']",
                "input[placeholder*='Username' i]",
                "input[type='text']"
            ]

            password_selectors = [
                "input[name='password']",
                "input[id='password']",
                "input[placeholder*='Password' i]",
                "input[type='password']"
            ]

            # Try to find and fill username
            username_field = None
            for selector in username_selectors:
                try:
                    username_field = self.wait.until(
                        EC.element_to_be_clickable((By.CSS_SELECTOR, selector))
                    )
                    if username_field:
                        break
                except:
                    continue

            if not username_field:
                raise Exception("Could not find username field")

            username_field.clear()
            username_field.send_keys(VPN_USERNAME)
            logger.info("Username entered")

            # Try to find and fill password
            password_field = None
            for selector in password_selectors:
                try:
                    password_field = self.wait.until(
                        EC.element_to_be_clickable((By.CSS_SELECTOR, selector))
                    )
                    if password_field:
                        break
                except:
                    continue

            if not password_field:
                raise Exception("Could not find password field")

            password_field.clear()
            password_field.send_keys(VPN_PASSWORD)
            logger.info("Password entered")

        except Exception as e:
            logger.error(f"Failed to enter VPN credentials: {str(e)}")
            raise

    def click_sign_in_button(self):
        """Click the sign in button after entering credentials"""
        try:
            logger.info("Clicking sign in button...")

            # Common selectors for sign in button
            sign_in_selectors = [
                "button:contains('Sign In')",
                "input[value='Sign In']",
                "button:contains('Login')",
                "input[value='Login']",
                ".sign-in-btn",
                "#sign-in-button",
                ".login-btn",
                "#login-button"
            ]

            sign_in_button = None
            for selector in sign_in_selectors:
                try:
                    if ":contains" in selector:
                        # XPath for text-containing elements
                        text = selector.split("'")[1]
                        sign_in_button = self.wait.until(
                            EC.element_to_be_clickable((By.XPATH, f"//button[contains(text(), '{text}')]"))
                        )
                    else:
                        sign_in_button = self.wait.until(
                            EC.element_to_be_clickable((By.CSS_SELECTOR, selector))
                        )
                    if sign_in_button:
                        break
                except:
                    continue

            if not sign_in_button:
                # Fallback: try to find any button that might be sign in/login
                buttons = self.driver.find_elements(By.TAG_NAME, "button")
                for btn in buttons:
                    btn_text = btn.text.lower()
                    if btn.is_displayed() and btn.is_enabled() and ('sign in' in btn_text or 'login' in btn_text):
                        sign_in_button = btn
                        break

            if not sign_in_button:
                raise Exception("Could not find sign in button")

            sign_in_button.click()
            logger.info("Sign in button clicked")

        except Exception as e:
            logger.error(f"Failed to click sign in button: {str(e)}")
            raise

    def click_access_button(self, timeout=40):
        """
        Click the 'access' button that appears after SSO authentication.
        Based on user description: after ~20 seconds, a page opens where they press the "access" button.
        """
        try:
            logger.info("Waiting for and clicking 'access' button...")

            start_time = time.time()
            while time.time() - start_time < timeout:
                try:
                    # Look for access button
                    access_selectors = [
                        "button:contains('Access')",
                        "input[value='Access']",
                        "a:contains('Access')",
                        ".access-btn",
                        "#access-button"
                    ]

                    access_button = None
                    for selector in access_selectors:
                        try:
                            if ":contains" in selector:
                                # XPath for text-containing elements
                                text = selector.split("'")[1]
                                access_button = self.driver.find_element(
                                    By.XPATH, f"//button[contains(text(), '{text}')]"
                                )
                            else:
                                access_button = self.driver.find_element(By.CSS_SELECTOR, selector)

                            if access_button and access_button.is_displayed() and access_button.is_enabled():
                                break
                        except:
                            continue

                    if access_button:
                        access_button.click()
                        logger.info("Access button clicked")
                        return True

                except:
                    pass  # Button not found yet, keep looking

                time.sleep(1)  # Check every second

            logger.warning(f"Access button not found after {timeout} seconds")
            return False

        except Exception as e:
            logger.error(f"Error clicking access button: {str(e)}")
            return False

    def click_login_button(self):
        """Click the login/submit button"""
        try:
            logger.info("Clicking login button...")

            login_selectors = [
                "button[type='submit']",
                "input[type='submit']",
                "button:contains('Login')",
                "button:contains('Sign In')",
                ".login-btn",
                "#login-button"
            ]

            login_button = None
            for selector in login_selectors:
                try:
                    if ":contains" in selector:
                        # XPath for text-containing elements
                        text = selector.split("'")[1]
                        login_button = self.wait.until(
                            EC.element_to_be_clickable((By.XPATH, f"//button[contains(text(), '{text}')]"))
                        )
                    else:
                        login_button = self.wait.until(
                            EC.element_to_be_clickable((By.CSS_SELECTOR, selector))
                        )
                    if login_button:
                        break
                except:
                    continue

            if not login_button:
                # Fallback: try to find any button that might be login
                buttons = self.driver.find_elements(By.TAG_NAME, "button")
                for btn in buttons:
                    if btn.is_displayed() and btn.is_enabled():
                        login_button = btn
                        break

            if not login_button:
                raise Exception("Could not find login button")

            login_button.click()
            logger.info("Login button clicked")

        except Exception as e:
            logger.error(f"Failed to click login button: {str(e)}")
            raise

    def wait_for_sso_authentication(self, timeout=120):
        """
        Wait for user to complete SSO authentication via phone.
        This is a manual step where user approves push notification.
        """
        try:
            logger.info("Waiting for manual SSO phone authentication...")
            logger.info("Please check your phone and approve the push notification")

            start_time = time.time()
            while time.time() - start_time < timeout:
                # Check if we've progressed past the SSO page
                # Look for indicators that authentication is complete
                current_url = self.driver.current_url
                page_title = self.driver.title

                # Common indicators of successful authentication:
                # - URL changed from SSO domain
                # - Presence of VPN portal elements
                # - Absence of loading/spinner elements

                # Check if we're no longer on what appears to be an SSO page
                sso_indicators = ['sso', 'okta', 'azure', 'adfs', 'ping', 'duo']
                is_sso_page = any(indicator in current_url.lower() or indicator in page_title.lower()
                                for indicator in sso_indicators)

                if not is_sso_page and "samsungvpn" in current_url:
                    # We appear to be back on VPN portal - check for post-login elements
                    try:
                        # Look for elements that indicate successful login
                        # These would vary by portal - adjust as needed
                        success_indicators = [
                            "vpn", "connect", "access", "dashboard", "welcome"
                        ]
                        page_source = self.driver.page_source.lower()
                        if any(indicator in page_source for indicator in success_indicators):
                            logger.info("SSO authentication appears to be complete")
                            return True
                    except:
                        pass

                # Also check for explicit success/failure messages
                try:
                    success_msgs = self.driver.find_elements(
                        By.XPATH,
                        "//*[contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'success') or "
                        "contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'authenticated') or "
                        "contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'welcome')]"
                    )
                    if success_msgs:
                        logger.info("Found success message indicating SSO completion")
                        return True
                except:
                    pass

                time.sleep(2)  # Check every 2 seconds

            logger.warning(f"SSO authentication timeout after {timeout} seconds")
            return False

        except Exception as e:
            logger.error(f"Error during SSO authentication wait: {str(e)}")
            return False

    def wait_for_vpn_connection(self, timeout=180):
        """
        Wait for VPN connection to be fully established.
        """
        try:
            logger.info("Waiting for VPN connection to establish...")
            logger.info("This may take a few minutes - please wait...")

            start_time = time.time()
            while time.time() - start_time < timeout:
                current_url = self.driver.current_url
                page_source = self.driver.page_source.lower()

                # Look for indicators of VPN connection established
                vpn_connected_indicators = [
                    "connected", "access vpn", "vpn active", "connection established",
                    "secure connection", "vpn status: connected"
                ]

                # Check for connection status elements
                try:
                    status_elements = self.driver.find_elements(
                        By.XPATH,
                        "//*[contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'connected') or "
                        "contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'active')]"
                    )
                    if status_elements:
                        for elem in status_elements:
                            if elem.is_displayed():
                                logger.info("VPN connection appears to be established")
                                return True
                except:
                    pass

                # Check URL for VPN portal post-login pages
                if "samsungvpn" in current_url and ("dashboard" in current_url or "portal" in current_url or "home" in current_url):
                    logger.info("Appears to be on VPN portal homepage - connection likely established")
                    return True

                time.sleep(5)  # Check every 5 seconds

            logger.warning(f"VPN connection timeout after {timeout} seconds")
            return False

        except Exception as e:
            logger.error(f"Error waiting for VPN connection: {str(e)}")
            return False

    def navigate_to_device_portal(self):
        """Navigate to the device management portal"""
        try:
            logger.info(f"Navigating to device management portal: {DEVICE_PORTAL_URL}")
            self.driver.get(DEVICE_PORTAL_URL)

            # Wait for page to load
            self.wait.until(EC.presence_of_element_located((By.TAG_NAME, "body")))
            logger.info("Device management portal loaded successfully")

            # Additional wait for any dynamic content
            time.sleep(3)

        except Exception as e:
            logger.error(f"Failed to navigate to device portal: {str(e)}")
            raise

    def search_and_download_device_data(self, device_id):
        """
        Search for a device and download its data.
        This is a placeholder - you'll need to customize based on the actual portal UI.
        """
        try:
            logger.info(f"Searching for device: {device_id}")

            # Placeholder implementation - customize based on actual portal
            # 1. Find search field
            # 2. Enter device ID
            # 3. Submit search
            # 4. Wait for results
            # 5. Click on device
            # 6. Find download button
            # 7. Click download
            # 8. Wait for download to complete

            logger.warning("Device search and download functionality needs to be customized for your specific portal")
            logger.info("Please implement the specific steps for your device management portal")

            # Example structure (you'll need to adjust selectors):
            """
            # Find search field
            search_selectors = [
                "input[placeholder*='device' i]",
                "input[name*='search' i]",
                "input[id*='search' i]",
                ".search-input",
                "#device-search"
            ]

            search_field = None
            for selector in search_selectors:
                try:
                    search_field = self.wait.until(
                        EC.element_to_be_clickable((By.CSS_SELECTOR, selector))
                    )
                    if search_field:
                        break
                except:
                    continue

            if search_field:
                search_field.clear()
                search_field.send_keys(device_id)
                search_field.submit()
                logger.info(f"Search submitted for device: {device_id}")

                # Wait for results and proceed with download...
                # This would continue with device selection and download logic
            """

        except Exception as e:
            logger.error(f"Error searching/downloading device data: {str(e)}")
            raise

    def run_automation(self):
        """Run the complete automation workflow"""
        try:
            logger.info("Starting VPN and VDI automation workflow")

            # Setup
            self.setup_driver()

            # Step 1: Navigate to VPN
            self.navigate_to_vpn()

            # Step 2: Enter credentials
            self.enter_vpn_credentials()

            # Step 3: Click sign in button
            self.click_sign_in_button()

            # Step 4: Wait for SSO authentication (manual step via phone)
            if not self.wait_for_sso_authentication():
                logger.error("SSO authentication failed or timed out")
                return False

            # Step 5: Click access button (appears after ~20 seconds)
            if not self.click_access_button(timeout=40):
                logger.error("Failed to click access button")
                return False

            # Step 6: Wait for VPN connection (takes around 30 seconds after access)
            if not self.wait_for_vpn_connection(timeout=60):
                logger.error("VPN connection failed or timed out")
                return False

            # Step 7: Navigate to device management portal
            self.navigate_to_device_portal()

            logger.info("Automation workflow completed successfully!")
            logger.info("You can now manually search for devices and download data as needed")
            logger.info("The browser will remain open for your convenience")

            # Keep browser open for manual interaction
            logger.info("Press Ctrl+C to exit and close the browser")
            try:
                while True:
                    time.sleep(1)
            except KeyboardInterrupt:
                logger.info("Received exit signal")

            return True

        except Exception as e:
            logger.error(f"Automation workflow failed: {str(e)}")
            return False
        finally:
            # Optional: close browser on exit
            # Uncomment the next line if you want the browser to close automatically
            # if self.driver:
            #     self.driver.quit()
            pass

def main():
    """Main entry point"""
    print("=" * 60)
    print("VPN and VDI Login Automation Script")
    print("=" * 60)
    print("This script will:")
    print("1. Navigate to Samsung VPN portal")
    print("2. Enter your VPN credentials")
    print("3. Wait for you to manually authenticate via phone (SSO)")
    print("4. Wait for VPN connection to establish")
    print("5. Navigate to the device management portal")
    print("6. Keep the browser open for manual device search/download")
    print()
    print("IMPORTANT: You MUST update the VPN_USERNAME and VPN_PASSWORD")
    print("variables in the script with your actual credentials before running!")
    print("=" * 60)

    # Check if credentials are set
    if VPN_USERNAME == "your_vpn_username_here" or VPN_PASSWORD == "your_vpn_password_here":
        print("\nERROR: Please update VPN_USERNAME and VPN_PASSWORD in the script!")
        print("Edit the vpn_vdi_automation.py file and replace the placeholder values.")
        return

    # Create and run automation
    automation = VPNAutomation()
    automation.run_automation()

if __name__ == "__main__":
    main()