====================
Application LBMethoD
====================

This is a brief description of the application functionality
It is best displayed on Full HD (1920 x 1080) resolution as the font is fixed size

Quick Start (LBMethoD.exe): Press Play button (or F5) ... and optionally:
 - enter full-screen with alt + enter
 - hide gui with F1
 - show particles with F9

A Lid-Driven Cavity (LDC) Simulation (CFD Hello World) with high turbulence/low viscosity starts.
The algorithm used is the Lattice Boltzmann Method (LBM) which indirectly solves the Navier-Stokes (NS) Equations with a statistical approach to molecular gas dynamics.
This is in contrast to the usual approach solving NS directly. Please note the detailed swirls on a 400 * 225 grid.

LBM is implemented with Vulkan glsl compute shader, the GUI system (dear imgui) has a custom Vulkan back-end and can be hidden with the F1 key. All shaders can be edited and reloaded at runtime (with the help of glslangValidator). The world can be navigated, akin to Autodesk Maya, with:
 - alt + LMB: orbit
 - alt + MMB: pan
 - alt + RMB: dolly (left-right slow, up-down fast)
 - mouse wheel: dolly

Additionally following hotkeys are available:
 - F1 : Hide/Show Gui
 - F5 : Play / Pause
 - F6 : Step
 - F7 : Reset
 - F8 : Reset Particles
 - F9 : Show/Hide Particles
 - F12: Show/Hide Display Plane
 - home: reset camera position
 - alt + enter: full-screen / windowed

In several sections of the gui we can (briefly):
 - choose between a detected Vulkan capable device and the CPU
 - choose initialization and simulation compute shaders,
   edit the compute grid resolution and compute work group size
 - edit the simulation with LBM related parameters (wall velocity, wall thickness)
 - display different properties of the velocity field
   - velocity lines and particles
   - show and hide scene objects as well as edit the background color
 - profile the simulation (compare to CPU or compare various work group sizes)
 - validate the simulation with well known data (Ghia et. al 1982) as well as analytic solution (channel flow)
 - export into EnSight Gold CFD format (known to crash on NVidia Systems)



Gui sections in Detail
======================


Compute Device
--------------
The listed Vulkan device is corresponds to the device determined at initialization step. Device selection is based on presentation support prioritizing discrete GPUs. CPU simulation is hard-coded to only one example, which is Lid-Driven Cavity used mainly for profiling.


Compute Parameter
-----------------
Two compute shaders, one for initialization (triggered with Reset Button on top) and one for the simulation loop. Each shader can be parsed, recompiled and its PSO reconstructed with RMB context menu on the widget. Experimentation with glsl code of the loop_D2Q9_ldc.comp shader is encouraged, some code is commented bellow 
search term: "// Ladd's momentum correction"
with which we achieve different effects when un-commented. If double precision is required both the shaders must have the _double suffix, as well as "Per Cell Value" bellow set to double.
As soon as we change any of the following values, the ghosted "No" Button turns to usable "Apply" to commit the settings.
With per cell values we specify how many values and what precision we need per cell. All the existing D2Q9 shaders require 17 values, the D3Q15 (WIP) would require 29 values.
Next we can set the grid resolution. RMB on each field displays a context menu with presets, RMB on "Grid Resolution" displays presets for both the fields. In any cases we can use the (proportionally scaled) window resolution.
Due to GPU memory access optimization we use only a one dimensional compute work group size. It must be set to an integer divisor of grid resolution x.
With "Steps per Cmd Buffer" we prerecord N simulation steps into one command buffer and accelerate the simulation. Velocities are accumulated when using D2Q9_ldc, and omitted with all other shaders. The former is useful to properly accelerate particles (see Display Parameter), the latter to simply accelerate simulation progress.


Simulation Parameter
--------------------
In this section we can parametrize the simulation behavior. RMB the section name "Simulation Parameter" to get some preset settings ("Unit Parameter" is the "usual" LDC simulation).
Parameter "Relaxation Rate Tau" is LBM related and a common setting to describe molecular collision behavior. It should stay between 0.5 and 2, the lower the setting the higher the viscosity and hence turbulence. Not each of the collision algorithm has the required stability to run low viscous fluids, Cascaded Drag should be used in low viscosity simulations.
The top wall moves with "Wall Velocity" in grid units and "Wall Thickness" sets the count of wall neighbor cells which are influenced by a moving wall (the higher the faster the fluid).
It is recommended to stick with algorithm "Cascaded Drag" as this is the most stable one. Multi-Relaxation Time algorithm (MRT) is not been implemented.
Subsections Simulation Details and Reynolds Number displays additional LBM parameters and CFD measure for turbulence.


Display Parameter
-----------------
Here we can show/hide and edit the fluid property display. RMB on "Draw Display Plane" widget shows a context to parse the only display shader in use, "draw_display.vert/.frag"
Some properties, e.g. curl, must be amplified to see any result. RMB on Amp Display Property shows context menu with differently sped widgets and presets as names.
In the additional subsections we can display and parametrize velocity lines, particles, show and hide scene objects as well as edit the background color.
Note that, by design, particles continue to evaluate the fluid velocity property even if the simulation is paused.


Profile Simulation
------------------
Originally implemented to compare Multi-Threaded CPU vs GPU performance, we can also experiment with various work group sizes. The measured time is CPU time starting from submitting the compute command buffer till the corresponding submission fence is signaled. GPU time measuring is not implemented so far. The meaning of MLups is Millions Lattice updates per second.


Validate Simulation
------------------
Validation is done visually with velocity lines/points. It is satisfying for CFD simulations when the velocity profiles are in "good" agreement with known or analytical data.
The first validation process compares to data from the work of Ghia et. al 1982, while the second process employs an analytical solution of the poiseuille flow (channel flow).


Export Ensight
--------------
Simulation data can be exported in the EnSight Gold CFD format. The process runs flawless on AMD APU (development system A10-7800 Radeon R7) but crashed on two NVdia Devices.


Known Issues
------------
 - crash when minimized (swapchain is lost but work issuing continues)
 - crash when in full-screen mode and swhich to another process
 - crash on Win8.1 AMD (drivers are not being updated!) when any shader feature using line drawing is enabled
 - issues with NVidia devices, crash when exporting (tested on two devices LunarG Vulkan layers)
 - resetting in CPU mode while paused does not immediately display the reset data (however, data IS reset)
 - resetting in CPU mode also triggers a validation error about vkFlushMappedMemoryRanges