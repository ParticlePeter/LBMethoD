======================================
Building LBMethoD and source libraries
======================================

To build LBMethoD.exe from source code the D tool chain must be installed. Any of the three should work, but its tested only with DMD (reference compiler) and LDC (LLVM front-end). The batch scripts build.bat and build_optimized.bat require DMD.
https://dlang.org/download.html

As of writing a bug in DMD v.2.077.1 emerged when linking for x64 bit with VS2017.
sc.ini in dmd folder must be edited to properly compile and link the sources:
line 53: LINKCMD=%VCINSTALLDIR%\bin\HostX86\x86\link.exe
change:  LINKCMD=%VCINSTALLDIR%\bin\HostX86\x64\link.exe

details: https://forum.dlang.org/post/qffzjttlcjzlgmmhkntv@forum.dlang.org