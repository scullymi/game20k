# The Tang Nano 20K on Windows

Windows binds both interfaces of the Nano's USB debugger (USB ID 0403:6010) to FTDI's serial
driver. openFPGALoader, which `g20k.py flash` uses, then cannot open the board and reports
`unable to open ftdi device: -4 (usb_open() failed)`. Interface 0, the JTAG side, needs the
WinUSB driver instead. [Zadig](https://zadig.akeo.ie) installs it, once per computer:

1. Start Zadig and turn on **Options → List All Devices**.
2. Select **USB Serial Converter A**.
3. Check that **USB ID** shows **0403 6010 00**. Anything else is not the Nano.
4. The current driver on the left is **FTDIBUS**. Choose **WinUSB** as the target on the right
   and click **Replace Driver**.

Interface 1 keeps FTDI's driver and stays a serial port (COM). Afterwards g20k.py can write the
board:

```bat
py g20k.py flash --download
```

Gowin's Programmer and `programmer_cli` use FTDI's driver on interface 0. To use them again,
switch back: in the Device Manager, under **Universal Serial Bus devices**, uninstall
**USB Debugger** (interface 0, now on WinUSB) together with its driver, then plug the Nano in
again.
