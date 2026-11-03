#!/usr/bin/env bash
# Drives an app's screen from adb the way a remote does: focus moves with TAB, OK presses.
# Taps are not used: on TVs, apps that draw a phone-sized window often ignore them. Sourced
# by dnsfilter.sh; uses the caller's dev. Must stay bash 3.2 compatible.

# The view nodes on screen, one per line, as uiautomator reports them. A dump fails while the
# app is busy ("could not get idle state"), so it is retried; returns 1 if none succeeded.
ui_nodes() {
  local xml i
  for i in $(seq 1 15); do
    xml=$(dev 'uiautomator dump /sdcard/dumbtv-ui.xml >/dev/null 2>&1; cat /sdcard/dumbtv-ui.xml; rm -f /sdcard/dumbtv-ui.xml')
    if [[ $xml == *'<node '* ]]; then
      printf '%s\n' "$xml" | tr '>' '\n' | grep '<node '
      return 0
    fi
    sleep 1
  done
  return 1
}

# ui_node ID: the node whose resource-id is PKG:id/ID; empty when it is not on screen or the
# screen could not be read.
ui_node() { ui_nodes | grep -m1 "resource-id=\"[^\"]*:id/$1\""; }

ui_checked() { [[ $(ui_node "$1") == *'checked="true"'* ]]; }

# ui_focus ID: presses TAB until ID has focus. A screen's focus order is a loop, so 40 presses
# visit every view of any screen this is used on. Keys are only pressed after a good read.
ui_focus() {
  local i nodes
  for i in $(seq 1 40); do
    nodes=$(ui_nodes) || return 1
    [[ $(printf '%s\n' "$nodes" | grep -m1 "resource-id=\"[^\"]*:id/$1\"") == *'focused="true"'* ]] && return 0
    dev input keyevent KEYCODE_TAB >/dev/null
  done
  return 1
}

ui_press() { ui_focus "$1" && dev input keyevent KEYCODE_DPAD_CENTER >/dev/null; }

# ui_tick ID: makes a checkbox ticked. It is pressed only when a read showed it unticked, so
# an unreadable screen can never untick it.
ui_tick() {
  local node
  node=$(ui_node "$1")
  [[ -n $node ]] || return 1
  [[ $node == *'checked="true"'* ]] && return 0
  ui_press "$1" || return 1
  sleep 1
  ui_checked "$1"
}

# ui_type TEXT: types one line into the focused field. `input text` reads %s as a space.
ui_type() { dev "input text '${1// /%s}'" >/dev/null; }
