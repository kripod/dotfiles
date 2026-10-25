#!/bin/zsh
# Sets up a Mac for web development. Safe to rerun, as every step checks first or writes the same
# value again. Dotfiles are only copied where missing, which keeps lines that installers add later.
# Stops at the first error.
set -euo pipefail

if (( EUID == 0 )) || [[ $(uname -m) != arm64 ]]; then
  print "Run as your own user, not with sudo, on an Apple silicon Mac" >&2
  exit 1
fi
trap 'print -P "%F{red}Stopped at the error above. Fix it and rerun.%f" >&2' ZERR

repo=${0:A:h}

append_once() {
  if ! grep -qxF "$2" "$1" 2>/dev/null; then
    print -r -- "$2" >>"$1"
  fi
}

add_login_item() {
  if ! osascript -e 'tell application "System Events" to get name of every login item' | grep -qw -- "${1:t:r}"; then
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$1\", hidden:false}" >/dev/null
  fi
}

setup_computer_name() {
  local current suggested model
  current=$(scutil --get ComputerName 2>/dev/null || true)
  # Factory names look like "Name’s MacBook Pro"
  if [[ -n $current && $current != *’s\ * ]]; then
    suggested=$current
  else
    model=$(system_profiler SPHardwareDataType | awk -F': ' '/Model Name/ { print $2 }')
    suggested="$USER-${${model:l}// /-}"
  fi
  read -r "computer_name?Computer name [$suggested]: "
  computer_name=${computer_name:-$suggested}

  sudo scutil --set ComputerName "$computer_name"
  # Network names allow only letters, digits and inner hyphens, up to 63 characters
  sudo scutil --set LocalHostName "$(print -r -- "$computer_name" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-63)"
}

setup_security() {
  # Touch ID for sudo. sudo_local survives macOS updates and keeps any lines it already has
  if ! grep -qE '^auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so' /etc/pam.d/sudo_local 2>/dev/null; then
    print 'auth       sufficient     pam_tid.so' | sudo tee -a /etc/pam.d/sudo_local >/dev/null
  fi
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on --setstealthmode on >/dev/null
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true

  # Warn only. Turning FileVault on shows a recovery key someone has to write down
  if ! fdesetup isactive >/dev/null; then
    print -P "%F{yellow}FileVault is off: turn it on in System Settings › Privacy & Security%f" >&2
  fi
}

setup_power() {
  # Never sleeps on the power adapter, even with the display off. Keeps builds and servers running
  sudo pmset -c sleep 0
}

setup_dotfiles() {
  local file target
  find "$repo/home" -type f -not -name .DS_Store -print0 |
    while IFS= read -r -d '' file; do
      target=$HOME/${file#$repo/home/}
      if [[ ! -e $target ]]; then
        mkdir -p "${target:h}"
        cp "$file" "$target"
      fi
    done
}

setup_homebrew() {
  # The installer also installs the Xcode Command Line Tools (git, clang) when they're missing
  if [[ ! -x /opt/homebrew/bin/brew ]]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  append_once ~/.zprofile 'eval "$(/opt/homebrew/bin/brew shellenv zsh)"'
  eval "$(/opt/homebrew/bin/brew shellenv zsh)"
  # Homebrew ignores DO_NOT_TRACK
  brew analytics off
  # Installs that pull in dependencies would otherwise wait for a y/N. The app checklist already asked.
  export HOMEBREW_NO_ASK=1
}

setup_mise() {
  brew install --formula mise
  # Shims for non-interactive shells like IDE tasks, activation for interactive ones
  append_once ~/.zprofile 'eval "$(mise activate zsh --shims)"'
  append_once ~/.zshrc 'eval "$(mise activate zsh)"'
  mise install
}

# Each optional app registers for the checklist with `offer <installer> <on|off> <label>`
offers=()
offer() {
  offers+=("$@")
}

offer install_chrome on "Browser: Google Chrome"
install_chrome() {
  brew install --cask google-chrome
  local handlers=~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist
  if [[ $(plutil -extract LSHandlers json -o - $handlers 2>/dev/null | jq -r '.[] | select(.LSHandlerURLScheme == "https") | .LSHandlerRoleAll') != com.google.chrome ]]; then
    # macOS asks to confirm the switch. Chrome only reads the flag when it isn't running yet.
    open -a "Google Chrome" --args --make-default-browser
  fi
}

offer install_firefox on "Browser: Firefox"
install_firefox() {
  brew install --cask firefox
}

offer install_vscode on "Dev: Visual Studio Code"
install_vscode() {
  brew install --cask visual-studio-code
}

offer install_claude_code on "Dev: Claude Code"
install_claude_code() {
  brew install --cask claude-code@latest
  # Shorter replies, fewer tokens
  local settings=~/.claude/settings.json
  mkdir -p ~/.claude
  if [[ ! -s $settings ]]; then
    print '{}' >$settings
  fi
  if ! jq -e '.outputStyle' $settings >/dev/null; then
    jq '.outputStyle = "Concise"' $settings >$settings.tmp
    mv $settings.tmp $settings
  fi
}

offer install_dory on "Dev: Dory (Docker containers)"
install_dory() {
  if [[ ! -d /Applications/Dory.app ]]; then
    # Installing by full name works untrusted, but a plain `brew upgrade` skips untrusted casks
    brew trust --cask augani/dory/dory
    brew install --cask augani/dory/dory
    # The first launch starts its engine and adds ~/.dory/bin to the shell profiles
    open -a Dory
  fi
}

offer install_postico on "Dev: Postico (PostgreSQL)"
install_postico() {
  brew install --cask postico
}

offer install_asimov on "Dev: Asimov (keeps node_modules and similar out of Time Machine)"
install_asimov() {
  brew install --formula asimov
  if ! brew services info asimov --json | jq -e '.[0].loaded' >/dev/null; then
    brew services start asimov
  fi
}

offer install_ffmpeg on "Media: FFmpeg"
install_ffmpeg() {
  brew install --formula ffmpeg
}

offer install_handbrake off "Media: HandBrake"
install_handbrake() {
  brew install --cask handbrake-app
}

offer install_keycastr off "Media: KeyCastr (shows keystrokes in recordings)"
install_keycastr() {
  brew install --cask keycastr
}

offer install_slack off "Work: Slack"
install_slack() {
  brew install --cask slack
  add_login_item /Applications/Slack.app
}

offer install_zoom off "Work: Zoom"
install_zoom() {
  brew install --cask zoom
}

offer install_office off "Work: Microsoft Word, Excel and PowerPoint"
install_office() {
  brew install --cask microsoft-word microsoft-excel microsoft-powerpoint
}

offer install_granola off "Work: Granola"
install_granola() {
  brew install --cask granola
}

offer install_qpdf off "Utility: qpdf (removes PDF passwords, merges PDFs)"
install_qpdf() {
  brew install --formula qpdf
}

offer install_tailscale off "Network: Tailscale"
install_tailscale() {
  # Asks to allow its network extension in Privacy & Security on first launch
  brew install --cask tailscale-app
}

choose_apps() {
  local -a items
  local i picked
  for (( i = 1; i <= $#offers; i += 3 )); do
    items+=("${offers[i+2]}" "${offers[i+1]}")
  done
  # Built-in multi-select dialog, fed with label and default pairs. Cancel stops the script
  picked=$(osascript - "${items[@]}" <<'EOF'
on run argv
  set labels to {}
  set checked to {}
  repeat with i from 1 to (count argv) by 2
    set end of labels to item i of argv
    if item (i + 1) of argv is "on" then set end of checked to item i of argv
  end repeat
  activate
  set picked to choose from list labels with title "setup.zsh" with prompt "Apps to install:" default items checked with multiple selections allowed and empty selection allowed
  if picked is false then error number -128
  set AppleScript's text item delimiters to linefeed
  return picked as text
end run
EOF
  )
  chosen_apps=(${(f)picked})
}

install_chosen_apps() {
  local i
  for (( i = 1; i <= $#offers; i += 3 )); do
    # (Ie) gives the index of an exact match, or 0
    if (( ${chosen_apps[(Ie)${offers[i+2]}]} )); then
      ${offers[i]}
    fi
  done
}

setup_rendering() {
  # Always-on scroll bars take up layout space like on Windows, which surfaces overflow and 100vw bugs
  defaults write -g AppleShowScrollBars -string Always
  # Renders text at its real weight, the way designs show it, without macOS's extra boldening
  defaults -currentHost write -g AppleFontSmoothing -int 0
}

setup_keyboard() {
  # Tab also reaches links and buttons, needed for testing keyboard navigation in browsers
  defaults write -g AppleKeyboardUIMode -int 2
  defaults write -g NSAutomaticCapitalizationEnabled -bool false
  defaults write -g NSAutomaticInlinePredictionEnabled -bool false
  defaults write -g NSAutomaticPeriodSubstitutionEnabled -bool false
  defaults write -g NSAutomaticSpellingCorrectionEnabled -bool false
  defaults write -g WebAutomaticSpellingCorrectionEnabled -bool false

  # macOS shortcuts that take VS Code's keys: Control + F5 (10, Run Without Debugging), F11 and
  # Shift + F11 (36, 37: Step Into and Out), Control + Space (60, Trigger Suggest). 61 is 60 with Option.
  # XML, since `{ enabled = 0 }` would store a string, not a boolean.
  local id
  for id in 10 36 37 60 61; do
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add $id '<dict><key>enabled</key><false/></dict>'
  done
}

setup_safari() {
  # Safari › Settings › Advanced › Show features for web developers. Safari reads this copy outside its
  # protected container, unlike Tab highlighting, which stays manual.
  defaults write com.apple.Safari.SandboxBroker ShowDevelopMenu -bool true
}

setup_finder() {
  # Exposes disguised names like invoice.pdf.app
  defaults write -g AppleShowAllExtensions -bool true
  defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
  defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
}

setup_privacy() {
  defaults write com.apple.AdLib allowApplePersonalizedAdvertising -bool false
}

setup_spotlight() {
  # macOS 27's Spotlight ignores .metadata_never_index, and its Search Privacy list needs root and
  # Full Disk Access to edit. That leaves a manual drag and drop
  if read -q "?Exclude ~/Coding from Spotlight now? [y/N] "; then
    mkdir -p ~/Coding
    print "\nDrag ~/Coding into Search Privacy at the bottom of the Spotlight settings."
    open "x-apple.systempreferences:com.apple.Spotlight-Settings.extension"
    open ~
  else
    print
  fi
}

# Personal preferences. Matters of taste, applied only when asked

prefer_appearance() {
  defaults write -g AppleInterfaceStyle -string Dark
  defaults write -g AppleIconAppearanceTheme -string RegularDark
  defaults write -g AppleReduceDesktopTinting -bool true
  # Clicking the scroll bar jumps to that spot instead of paging
  defaults write -g AppleScrollerPagingBehavior -bool true
  defaults write -g com.apple.sound.uiaudio.enabled -bool false
  defaults -currentHost write com.apple.controlcenter BatteryShowPercentage -bool true
  # Hides the Spotlight menu bar icon. Command + Space still works
  defaults -currentHost write com.apple.controlcenter Spotlight -int 8
  defaults -currentHost write com.apple.Spotlight MenuItemHidden -bool true
}

prefer_keyboard() {
  defaults write -g KeyRepeat -int 2
  defaults write -g InitialKeyRepeat -int 25
  defaults write com.apple.keyboard.preferences IsMixmojiSuggestionsEnabled -bool false
  # Accessibility zoom and contrast shortcuts off
  local id
  for id in {15..26}; do
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add $id '<dict><key>enabled</key><false/></dict>'
  done
}

prefer_trackpad() {
  # 262144 is the Control key: Control + scroll zooms the screen
  local domain
  for domain in com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad; do
    defaults write $domain Clicking -bool true
    defaults write $domain HIDScrollZoomModifierMask -int 262144
    # Smart zoom off
    defaults write $domain TrackpadTwoFingerDoubleTapGesture -int 0
  done
  defaults -currentHost write -g com.apple.mouse.tapBehavior -int 1
  defaults -currentHost write -g com.apple.trackpad.twoFingerDoubleTapGesture -int 0
  defaults write -g com.apple.trackpad.scaling -float 1.5
  # Writing this can need Full Disk Access, which is too much to give a terminal that runs AI agents
  {
    defaults write com.apple.universalaccess closeViewScrollWheelToggle -bool true &&
      defaults write com.apple.universalaccess closeViewScrollWheelModifiersInt -int 262144
  } 2>/dev/null ||
    print -P "%F{yellow}Skipped Control + scroll zoom: turn it on in System Settings › Accessibility › Zoom%f" >&2
}

prefer_dock() {
  defaults write com.apple.dock autohide -bool true
  defaults write com.apple.dock orientation -string left
  defaults write com.apple.dock launchanim -bool false
  defaults write com.apple.dock mineffect -string scale
  defaults write com.apple.dock minimize-to-application -bool true
  defaults write com.apple.dock show-recents -bool false
  # Spaces keep their order instead of following the most recent use
  defaults write com.apple.dock mru-spaces -bool false
  defaults write com.apple.dock expose-group-apps -bool true
  defaults write com.apple.dock wvous-tr-corner -int 12 # Notification Center
  defaults write com.apple.dock wvous-br-corner -int 4  # Desktop
  defaults write com.apple.dock wvous-bl-corner -int 10 # Put display to sleep
  defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
  defaults write com.apple.WindowManager EnableTiledWindowMargins -bool false
  defaults write com.apple.WindowManager HideDesktop -bool true

  local -a apps=(
    /System/Applications/Calendar.app
    /System/Applications/Mail.app
    /Applications/Slack.app
    "/Applications/Visual Studio Code.app"
    "/Applications/Postico 2.app"
    "/Applications/Google Chrome.app"
    /Applications/Safari.app
  )
  local app
  if read -q "?Replace the Dock's apps with ${(j:, :)${apps[@]:t:r}}, without the Downloads stack? [y/N] "; then
    print
    defaults write com.apple.dock persistent-others -array
    defaults write com.apple.dock persistent-apps -array
    for app in $apps; do
      if [[ -e $app ]]; then
        # :A resolves Safari's symlink, otherwise the Dock labels it Safari.app
        defaults write com.apple.dock persistent-apps -array-add \
          "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>${app:A}</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
      fi
    done
  else
    print
  fi
}

prefer_finder() {
  defaults write com.apple.finder FXPreferredViewStyle -string Nlsv # List view
  defaults write com.apple.finder NewWindowTarget -string PfHm      # Home folder
  defaults write com.apple.finder FXDefaultSearchScope -string SCcf # Search the current folder
  defaults write com.apple.finder FXRemoveOldTrashItems -bool true
  defaults write com.apple.finder ShowPathbar -bool true
  defaults write com.apple.finder ShowStatusBar -bool true
  defaults write com.apple.finder _FXSortFoldersFirst -bool true
  defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
  defaults write -g NSDocumentSaveNewDocumentsToCloud -bool false
}

prefer_terminal() {
  # MonoLisa is a paid font, so it's installed by hand from monolisa.dev and never kept in this repo.
  # These are v1's file and font names. v3 renamed them.
  local -a fonts=(~/Library/Fonts/MonoLisa-Regular.*(N) /Library/Fonts/MonoLisa-Regular.*(N))
  if (( $#fonts )); then
    osascript -e 'tell application "Terminal" to tell settings set "Basic"' \
      -e 'set font name to "MonoLisa-Regular"' -e 'set font size to 14' -e 'set font antialiasing to true' \
      -e 'end tell'
  else
    print -P "%F{yellow}MonoLisa isn't installed. Get it from monolisa.dev and rerun to use it in Terminal%f" >&2
  fi
}

prefer_screenshots() {
  defaults write com.apple.screencapture show-thumbnail -bool false
  defaults write com.apple.screencapture showsClicks -bool true
}

prefer_privacy() {
  defaults write com.apple.assistant.support "Assistant Enabled" -bool false
  # Passwords deletes verification codes from Messages and Mail once they're used
  defaults write com.apple.onetimepasscodes DeleteVerificationCodes -bool true
}

prefer_login() {
  # Windows don't reopen after logging back in
  defaults write com.apple.loginwindow TALLogoutSavesState -bool false
  add_login_item /System/Applications/Mail.app
}

apply_settings() {
  # Applies keyboard shortcuts and trackpad settings without logging out
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  # Restarting Finder cancels any copy it has in progress
  killall Dock Finder SystemUIServer ControlCenter 2>/dev/null || true
}

setup_git() {
  # gh is git's HTTPS credential helper in ~/.gitconfig
  brew install --formula gh
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    gh auth login --hostname github.com --git-protocol https --web
  fi

  if ! git config --global user.email >/dev/null; then
    git config --global user.name "$(gh api user --jq '.name // .login')"
    git config --global user.email "$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
  fi

  if read -q "?Set up git commit signing for this machine? [y/N] "; then
    print
    setup_git_signing
  else
    print
  fi
}

setup_git_signing() {
  # One key per machine, kept out of backups. No passphrase, so signing never prompts. FileVault
  # encrypts it at rest.
  local key=~/.ssh/id_ed25519_signing
  if [[ ! -f $key ]]; then
    ssh-keygen -t ed25519 -C "git-signing $computer_name" -f $key -N ''
    tmutil addexclusion $key
  fi

  # The scope to manage signing keys is only held while needed
  local signing_keys
  gh auth refresh --hostname github.com --scopes admin:ssh_signing_key
  signing_keys=$(gh api user/ssh_signing_keys --jq '.[].key')
  if [[ $signing_keys != *$(cut -d' ' -f2 $key.pub)* ]]; then
    gh ssh-key add $key.pub --type signing --title "$computer_name"
    signing_keys=$(gh api user/ssh_signing_keys --jq '.[].key')
  fi
  gh auth refresh --hostname github.com --remove-scopes admin:ssh_signing_key

  # All of the account's signing keys, to verify commits made on other machines
  local email signing_key
  email=$(git config --global user.email)
  mkdir -p ~/.config/git
  for signing_key in ${(f)signing_keys}; do
    append_once ~/.config/git/allowed_signers "$email namespaces=\"git\" $signing_key"
  done
  git config --file ~/.config/git/signing gpg.format ssh
  git config --file ~/.config/git/signing user.signingKey "~/.ssh/id_ed25519_signing"
  git config --file ~/.config/git/signing gpg.ssh.allowedSignersFile "~/.config/git/allowed_signers"
  git config --file ~/.config/git/signing commit.gpgSign true
}

sudo -v
setup_computer_name
choose_apps
setup_security
setup_power
setup_dotfiles
setup_homebrew
setup_mise
install_chosen_apps
setup_rendering
setup_keyboard
setup_safari
setup_finder
setup_privacy
setup_spotlight
if read -q "?Apply personal preferences (dark mode, Dock on the left, tap to click, Trash emptied after 30 days, …)? [y/N] "; then
  print
  prefer_appearance
  prefer_keyboard
  prefer_trackpad
  prefer_dock
  prefer_finder
  prefer_terminal
  prefer_screenshots
  prefer_privacy
  prefer_login
else
  print
fi
apply_settings
setup_git

print "Done. Still manual: App Store apps, logging in to apps, and Tab highlighting in Safari › Settings › Advanced."
