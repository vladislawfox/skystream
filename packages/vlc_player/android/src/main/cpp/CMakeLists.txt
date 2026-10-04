cmake_minimum_required(VERSION 3.18.1)

# The one libVLC call libvlc-android does not expose in Java - see
# vlc_player_geometry.c. Links nothing of libVLC's: the symbol is resolved at
# run time from the libvlc.so the AAR ships and has already loaded.
project(vlc_player_geometry C)

add_library(vlc_player_geometry SHARED vlc_player_geometry.c)
target_link_libraries(vlc_player_geometry dl)
