PSN packages drop zone
======================

Put PlayStation 3 PSN files here:

  - .pkg files: the game itself, its updates and DLC
  - .rap files: the licences that belong to them

Then, on the device, open Main menu > Settings > Library and choose
"Install PSN packages". RetroForge installs everything in this folder in
one go and the game appears in your PlayStation 3 library, named after
itself.

Files that installed correctly are DELETED from this folder: the
installed game lives on the device from then on, so the .pkg is not
needed twice. Files that failed stay here so you can see them and try
again (a corrupt download, or a .pkg that is not a PS3 package).

This folder is the only place RetroForge ever deletes your files.

Notes:
  - Order does not matter; licences can be added later too.
  - Updates and DLC install into the game you already have; they never
    make a second entry in the library.
  - The game's entry in ~/roms/ps3 is a small "<Game Name>.psn" file.
    Renaming it renames the library entry; deleting it removes the entry
    (the installed game itself stays on the device).
