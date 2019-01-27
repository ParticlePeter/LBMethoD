==================================
Code LBMethoD and source libraries
==================================

LBMethoD is written in the D programming language (DLang), which is akin to C++ in concept and static as well as dynamic linking to C and C++ libraries is possible. This project uses the C library GLFW (linked dynamically) and the C++ library dear imgui (linked statically).


Used language features
----------------------
Some heavily used language features distinct to C++ should be noted here to ease source code reading:

Modules: D uses symbolic imports instead of file #includes. Visibility of imported symbols can be limited to function scopes.

Alias this: exactly one inner_struct can be tagged as alias inner_struct this; inside of an outer_struct. Members and methods of inner_struct can be used directly through outer_struct. Functions which accept inner_struct as parameter now also accept outer_struct.

Unified function call syntax (UFCS): function calls can be prefixed with their first parameter and the dot operator, e.g. device.vkGetDeviceQueue( family_index, ... ) instead of vkGetDeviceQueue( device, family_index, ... )

Pointer syntax: Member/method access through a pointer is the same as access through an object, with the dot operator.


Source Code
-----------
All glsl shader code as well as project and library code found in source and shader directories is written by myself with one exception, DerelictGLFW in the "derelict" sub folder, which is used to link to GLFW library. Shader code is in shader directory, project sources are in files (modules) directly in the source folder, while additional source libraries are in sub folders.


Source libraries
----------------
DLSL	: math library mimicking glsl code in syntax and functionality (based on gl3n library)
ErupteD	: DLang Vulkan loader, auto-generated from the Vulkan Docs
ImGui	: DLang function signatures and types of dear ImGui C++ library for static linking
VDrive	: Thin Vulkan abstraction to reduce the amount of boiler plate code


VDrive concept
--------------
The Library came to live during intensive experimenting with and learning Vulkan. Constructing various Vulkan objects requires a significant amount of boilerplate code with plain C API, in particular specifying fields of CreateInfo structures. In VDrive such structs (with meaningful default values) are composed with the constructed objects in Meta_Structs which significantly reduces required code. E.g. a Pipeline State Object can be created in 20 lines of code instead (see: module gui, line 1980).


Lattice Boltzmann Method (LBM)
------------------------------
LBM is a way to approach molecular gas dynamics with statistical means. The simulation considers seven dimensional probability functions f(r, v, t) in so called phase space, the probability to find a particle at position r with velocity v at time t. Its discretized variant is ideally suited for gpu computations, each cell of an equidistant grid requires only the information stored at its directly neighboring cells to determine its next step state. Each cell stores (up to) count of neighbor cells probabilities (float value) to move towards these neighbors, plus one rest probability. For a 2D grid this would be 9 floats.
The basic algorithm is similar to playing billiard, it consist of two steps:
stream	: probabilities stream from one cell into their neighbor cells
collide	: probabilities incoming into one cell collide and all probabilities are redistributed

Macroscopic properties velocity and density can be derived from the probabilities. The sum of all probabilities (vector length) is the cell density and sum of all probability vectors divided by the density is resulting the cell velocity.
Detailed information about the general concept with respect to (obsolete) gpu implementation can be found here:
https://developer.nvidia.com/gpugems/GPUGems2/gpugems2_chapter47.html


Implementation
--------------
Probabilities are stored in one linear texel buffer in a struct of arrays fashion. They are stored consecutively, first rest probabilities of all cells, than probabilities in positive x direction of all cells, etc. This is to optimize data read/writes through coalesced memory access. Non-rest probabilities are double-buffered. With this structure streaming in +-X corresponds in moving coalesced one array index to right/left and streaming in +-Y is moving coalesced count-of-row-cells to right/left.
Grid initialization and basic algorithm is implemented in various compute shaders. Boundary conditions are part of the stream step and hard-coded into shaders. Various collision algorithms are implemented, with complexity being directly proportional to stability. Algorithms are selected utilizing specialization constants, invoking a PSO rebuild on the application side. This is also true for the local work group size.
Macroscopic properties velocity and density are stored into one layered 2D image (with 3D (WIP) in mind). The display of the image is also parametrized with different algorithms within one ueber shader (draw_display).
All PSOs (plane, line/point and particle) but the gui PSO are without input assembly specification and rely solely on shader build-in vertex and instance index. The flexibility of this approach is especially noticeable with the draw_line shader.


Application structure (modules)
-------------------------------
appstate.d: VDrive_State "app" struct is the core application brain. It manages update and draw functions as well as simulation transport. Play and profile functions are function pointers which can be reassigned for e.g. export purpose.

gui.d: VDrive_Gui_State "gui" wraps VDrive_State (alias gui this) and adds gui related data. Through this layered approach we can choose to compile a gui-less variant using a compile time macro. We can completely bypass the gui module at runtime when compiled with gui.

resources.d: (re)construction of Vulkan objects swapchain, sync primitives, (shared) memory objects (several UBOs), descriptor set, render pass, command pool and prerecorded command buffers. It does not manage its own data, hence no data struct. Functions inside this module create and update general Vulkan objects found in VDrive_State struct.

simulate.d: VDrive_Simulate_State "sim" holds Vulkan resources for the compute work like probability buffer and macroscopic image, compute PSO and command buffers, as well as a compute uniform buffer. Multiple simulation steps can be prerecorded into one command buffer, significantly increasing performance and visual speed. The struct also holds compute and simulation (lbm related) parameter. It is a member of VDrive_State.

visualize.d: VDrive_Visualize_State "vis" manages display plane, particle as well as general line/point resources for e.g. velocity lines but also axis and grid lines. Visualization related parameter editable through the gui are also composed in this struct. Only particles and the display plane are drawn in gui less mode and can be hidden with hotkeys. The struct is a member of VDrive_State.

initialize.d: init instance, enable validation, select and init Vulkan device and derive its queues. All the initialized data is stored in VDrive_State.

input.d: receive and parse event messages from glfw. Some of the callbacks are reassigned through module gui.d, but also forwarded to input.d callbacks.

cpustate: VDrive_Cpu_State "cpu" manages host resources to run a multi-threaded lid driven cavity CPU simulation. The computed macroscopic properties are written into a staging buffer, then copied into the macroscopic image and displayed by Vulkan. 

exportstate.d: VDrive_Export_State "exp" has additional Vulkan resources solely for export purpose. Macroscopic image data must be rearranged as einsight does not support an interleaved vector. The arrangement is done in compute shaders using either the populations buffer or the image buffer. Memory backing the export buffers is allocated with an additional portion for a binary header and directly written to disk per frame (all defined in ensight.d).

main.d: one to rule them all.


Additional Notes
----------------
In Gui mode all graphics command buffers are recorded each frame, while in gui-less mode they are prerecorded and reused. When Gui is turned off the latter ones are re-recorded to reflect displayed features (so far only the display plane and particles).


Github
------
https://github.com/ParticlePeter/LBMethoD
https://github.com/ParticlePeter/ErupteD
https://github.com/ParticlePeter/V-Drive
https://github.com/ParticlePeter/DLSL
https://github.com/ParticlePeter/imgui_lib

https://github.com/DerelictOrg/DerelictGLFW3






