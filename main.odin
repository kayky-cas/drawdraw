package main

import "base:runtime"
import "core:c"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

state: struct {
	window:   ^sdl.Window,
	surface:  vk.SurfaceKHR,
	instance: vk.Instance,
	p_device: vk.PhysicalDevice,
	device:   vk.Device,
	ctx:      runtime.Context,
}

sdl_assert :: proc(ret: bool, loc := #caller_location) {
	if !ret {
		log.panic(loc, "SDL_ERROR:", sdl.GetError())
	}
}

vk_assert :: proc(result: vk.Result, msg: string = "", loc := #caller_location) {
	if result != .SUCCESS {
		log.panic(loc, "VK_ERROR:", msg)
	}
}

when ODIN_OS != .Darwin {
	CHECK_VALIDATION_LAYERS :: true
} else {
	CHECK_VALIDATION_LAYERS :: false
}

DEVICE_EXTENSIONS :: []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
VALIDATION_LAYERS :: []cstring{"VK_LAYER_KHRONOS_validation"}

check_validation_layer_support :: proc() -> bool {
	layer_count: u32
	vk.EnumerateInstanceLayerProperties(&layer_count, nil)

	avaliable_layer_properties := make([]vk.LayerProperties, layer_count)
	defer delete(avaliable_layer_properties)

	vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(avaliable_layer_properties))

	for validation_layer in VALIDATION_LAYERS {
		layer_found := false

		for i := 0; i < int(layer_count); i += 1 {
			layer_name := cstring(&avaliable_layer_properties[i].layerName[0])

			if layer_name == validation_layer {
				layer_found = true
				break
			}
		}

		if !layer_found {
			return false
		}
	}

	return true
}

pick_physical_device :: proc() -> (vk.PhysicalDevice, int, int) {
	device_count: u32
	vk.EnumeratePhysicalDevices(state.instance, &device_count, nil)

	devices := make([]vk.PhysicalDevice, device_count)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(state.instance, &device_count, raw_data(devices))

	device_loop: for device in devices {
		extension_count: u32
		vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)

		avaliable_extension_properties := make(
			[]vk.ExtensionProperties,
			extension_count,
			allocator = context.temp_allocator,
		)
		defer delete(avaliable_extension_properties, allocator = context.temp_allocator)
		vk.EnumerateDeviceExtensionProperties(
			device,
			nil,
			&extension_count,
			raw_data(avaliable_extension_properties),
		)

		required_ext_supported := true

		for device_ext in DEVICE_EXTENSIONS {
			found := false

			for &avaliable_ext in avaliable_extension_properties {
				avaliable_ext_name := cstring(&avaliable_ext.extensionName[0])

				if device_ext == avaliable_ext_name {
					found = true
					break
				}
			}

			if !found {
				continue device_loop
			}
		}

		surface_format_count, surface_present_mode_count := get_surface_swapchain_counts(device)

		if surface_format_count <= 0 || surface_present_mode_count <= 0 {
			continue
		}

		queue_family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)

		queue_families := make(
			[]vk.QueueFamilyProperties,
			queue_family_count,
			allocator = context.temp_allocator,
		)
		defer delete(queue_families, allocator = context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(
			device,
			&queue_family_count,
			raw_data(queue_families),
		)

		graphic_family := -1
		present_family := -1

		for &queue_family, index in queue_families {
			if vk.QueueFlag.GRAPHICS in queue_family.queueFlags {
				graphic_family = index
			}

			present_support: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(
				device,
				u32(index),
				state.surface,
				&present_support,
			)

			if present_support {
				present_family = index
			}

			if present_family != -1 && graphic_family != -1 {
				return device, graphic_family, present_family
			}
		}
	}

	return nil, -1, -1
}

get_surface_swapchain_counts :: proc(
	p_device: vk.PhysicalDevice,
) -> (
	surface_format_count: u32,
	surface_present_mode_count: u32,
) {
	vk.GetPhysicalDeviceSurfaceFormatsKHR(p_device, state.surface, &surface_format_count, nil)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		p_device,
		state.surface,
		&surface_present_mode_count,
		nil,
	)

	return
}

create_swap_chain :: proc(allocator := context.allocator) {
	surface_format_count, surface_present_mode_count := get_surface_swapchain_counts(
		state.p_device,
	)

	if surface_format_count == 0 {
		log.panic("Swap chain support not available (no formats)")
	}

	if surface_present_mode_count == 0 {
		log.panic("Swap chain support not available (no present modes)")
	}

	surface_formats := make([]vk.SurfaceFormatKHR, surface_format_count, allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		state.p_device,
		state.surface,
		&surface_format_count,
		raw_data(surface_formats),
	)

	surface_format := surface_formats[0]

	for &format in surface_formats {
		if format.colorSpace == .SRGB_NONLINEAR && format.format == .B8G8R8_SRGB {
			surface_format = format
			break
		}
	}

	surface_present_modes := make([]vk.PresentModeKHR, surface_present_mode_count, allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		state.p_device,
		state.surface,
		&surface_present_mode_count,
		raw_data(surface_present_modes),
	)

	surface_present_mode := surface_present_modes[0]

	for &present_mode in surface_present_modes {
		if present_mode == .MAILBOX {
			surface_present_mode = present_mode
			break
		}
	}

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(state.p_device, state.surface, &capabilities)

	swap_chain_extent := choose_swap_extent(&capabilities)
	log.info("Swap chain extent", swap_chain_extent)
}

choose_swap_extent :: proc(capabilities: ^vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != 0xFFFFFFFF {
		return capabilities.currentExtent
	}

	width, height: c.int
	sdl.GetWindowSize(state.window, &width, &height)

	return vk.Extent2D {
		width = math.clamp(
			u32(width),
			capabilities.minImageExtent.width,
			capabilities.maxImageExtent.width,
		),
		height = math.clamp(
			u32(height),
			capabilities.minImageExtent.height,
			capabilities.maxImageExtent.height,
		),
	}
}

main :: proc() {
	logger := log.create_console_logger()
	context.logger = logger

	state.ctx = context

	sdl_assert(sdl.Init({.VIDEO}))
	defer sdl.Quit()

	when ODIN_OS == .Darwin {
		sdl_assert(
			sdl.Vulkan_LoadLibrary(
				"./MoltenVK/Package/Latest/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib",
			),
		)
		defer sdl.Vulkan_UnloadLibrary() // I don't know how "when" scopes work
	}

	state.window = sdl.CreateWindow("DrawDraw", 800, 600, {.VULKAN})
	sdl_assert(state.window != nil)
	defer sdl.DestroyWindow(state.window)

	vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))

	when CHECK_VALIDATION_LAYERS {
		if !check_validation_layer_support() {
			log.fatal("validation layers requested, but not available!")
			os.exit(1)
		}
	}

	application_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "DrawDraw",
		applicationVersion = vk.MAKE_VERSION(0, 0, 1),
		pEngineName        = "KEngine",
		engineVersion      = vk.MAKE_VERSION(0, 0, 1),
		apiVersion         = vk.API_VERSION_1_0,
	}

	instance_create_info := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &application_info,
	}

	sdl_vk_extensions := sdl.Vulkan_GetInstanceExtensions(
		&instance_create_info.enabledExtensionCount,
	)

	when CHECK_VALIDATION_LAYERS {
		debug_ext_names := make([]cstring, instance_create_info.enabledExtensionCount + 1)

		mem.copy(
			raw_data(debug_ext_names),
			sdl_vk_extensions,
			int(instance_create_info.enabledExtensionCount) * size_of(cstring),
		)

		debug_ext_names[instance_create_info.enabledExtensionCount] =
			vk.EXT_DEBUG_UTILS_EXTENSION_NAME

		instance_create_info.enabledExtensionCount += 1
		instance_create_info.ppEnabledExtensionNames = raw_data(debug_ext_names)
	} else {
		instance_create_info.ppEnabledExtensionNames = sdl_vk_extensions
	}

	if instance_create_info.ppEnabledExtensionNames == nil {
		log.panic("Failed to get required extensions from SDL")
	}

	for i in 0 ..< instance_create_info.enabledExtensionCount {
		log.info("Extension:", instance_create_info.ppEnabledExtensionNames[i])
	}

	when CHECK_VALIDATION_LAYERS {
		instance_create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
		instance_create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)

		debug_utils_messenger_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
			messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = proc "c" (
				severity: vk.DebugUtilsMessageSeverityFlagsEXT,
				_: vk.DebugUtilsMessageTypeFlagsEXT,
				data: ^vk.DebugUtilsMessengerCallbackDataEXT,
				_: rawptr,
			) -> b32 {
				context = state.ctx

				level: log.Level = .Debug

				if .ERROR in severity do level = .Error
				if .WARNING in severity do level = .Warning
				if .INFO in severity do level = .Info

				log.log(level, data.pMessage)

				return false
			},
		}

		instance_create_info.pNext = &debug_utils_messenger_create_info
	} else {
		instance_create_info.enabledLayerCount = 0
		instance_create_info.pNext = nil
	}

	vk_assert(
		vk.CreateInstance(&instance_create_info, nil, &state.instance),
		"failed to create instance!",
	)
	defer vk.DestroyInstance(state.instance, nil)

	vk.load_proc_addresses_instance(state.instance)

	sdl_assert(sdl.Vulkan_CreateSurface(state.window, state.instance, nil, &state.surface))
	defer sdl.Vulkan_DestroySurface(state.instance, state.surface, nil)

	graphics_family, present_family: int
	state.p_device, graphics_family, present_family = pick_physical_device()
	if state.p_device == nil {
		log.panic("Failed to find a suitable GPU")
	}

	unique_queue_families := []int{graphics_family, present_family}

	queue_create_info_count := int(graphics_family != present_family) + 1
	queue_create_infos := make([]vk.DeviceQueueCreateInfo, queue_create_info_count)
	defer delete(queue_create_infos)

	queue_priority: f32 = 1.0
	for i in 0 ..< queue_create_info_count {
		queue_create_infos[i] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = u32(unique_queue_families[i]),
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}
	}

	device_features: vk.PhysicalDeviceFeatures

	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = u32(queue_create_info_count),
		pQueueCreateInfos       = raw_data(queue_create_infos),
		pEnabledFeatures        = &device_features,
		enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
		ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
	}

	when CHECK_VALIDATION_LAYERS {
		device_create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
		device_create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)
	}

	vk_assert(
		vk.CreateDevice(state.p_device, &device_create_info, nil, &state.device),
		"failed to create logical device",
	)
	defer vk.DestroyDevice(state.device, nil)

	vk.load_proc_addresses_device(state.device)

	graphics_queue: vk.Queue
	vk.GetDeviceQueue(state.device, u32(graphics_family), 0, &graphics_queue)

	present_queue: vk.Queue
	vk.GetDeviceQueue(state.device, u32(present_family), 0, &present_queue)

	create_swap_chain()

	event: sdl.Event
	quit := false

	for !quit {
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				quit = true
			}
		}
	}
}
