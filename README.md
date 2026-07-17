# VPN and VDI Login Automation Script

This Python script automates the process of logging into Samsung VPN and accessing the SmartDSI device management portal.

## Features

- Automates navigation to Samsung VPN SSL portal
- Enters VPN credentials automatically
- Clicks "Sign In" button after credential entry
- Waits for manual SSO phone authentication (push notification)
- Clicks "Access" button that appears after ~20 seconds
- Waits for VPN connection establishment (takes ~30 seconds after access)
- Navigates to device management portal
- Keeps browser open for manual device search and download
- Comprehensive logging for troubleshooting

## Requirements

- Python 3.x
- Google Chrome browser
- Internet connection

## Installation

1. Install required Python packages:
   ```bash
   pip install selenium webdriver-manager
   ```

2. Update the script with your credentials:
   - Open `vpn_vdi_automation.py`
   - Replace `your_vpn_username_here` with your actual VPN username
   - Replace `your_vpn_password_here` with your actual VPN password

## Usage

1. Run the script:
   ```bash
   python vpn_vdi_automation.py
   ```

2. The script will:
   - Launch Chrome with your existing profile
   - Navigate to the Samsung VPN portal
   - Enter your credentials automatically
   - Pause for you to manually approve the SSO push notification on your phone
   - Wait for VPN connection to establish
   - Navigate to the SmartDSI device management portal
   - Keep the browser open for you to manually search devices and download files

3. To exit, press `Ctrl+C` in the terminal

## Important Notes

### Security
- The script currently stores credentials in plain text within the script file
- For better security, consider:
  - Using environment variables
  - Using an encrypted configuration file
  - Entering credentials manually at runtime (would require script modification)

### Customization Needed
The script includes placeholders for device search and download functionality that you'll need to customize based on your specific device management portal UI:

1. **Device Search**: You'll need to identify the correct selectors for:
   - Search input field
   - Search submit button/action

2. **Device Selection**: After search results appear, you'll need to:
   - Identify how to select the correct device from results
   - Navigate to the device details page

3. **Download Functionality**: For downloading device data:
   - Identify the download button/link selectors
   - Handle any download confirmation dialogs
   - Verify download completion

### Chrome Profile
The script uses your existing Chrome profile to maintain sessions and cookies, which helps with:
- SSO authentication persistence
- Avoiding repeated login prompts
- Maintaining any existing VPN portal sessions

### .ICA File Handling
The script includes Chrome preferences to prevent .ica files from opening automatically upon download, which addresses the issue where these files were set to open instantly.

## Troubleshooting

### Common Issues

1. **Element Not Found Errors**
   - The portal UI may have changed
   - Update the CSS selectors in the script to match current elements
   - Use browser developer tools to inspect and find correct selectors

2. **Timeout Issues**
   - Adjust timeout values in `wait_for_sso_authentication()` and `wait_for_vpn_connection()`
   - Network speed or portal performance may affect timing

3. **Authentication Problems**
   - Ensure your VPN credentials are correct
   - Verify that SSO push notifications are working on your phone
   - Check if any additional authentication steps are required

### Logging
- Detailed logs are saved to `vpn_vdi_automation.log`
- Console output shows real-time progress
- Check logs for detailed error information

## Disclaimer
This script is for automating legitimate access to authorized systems. Ensure you have proper authorization to automate access to your organization's VPN and device management systems.

## License
MIT License - feel free to modify and adapt for your specific needs.