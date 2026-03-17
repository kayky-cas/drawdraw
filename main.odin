package main

import "core:fmt"
import "core:log"
import "core:os"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

sdl_assert :: proc(ret: bool, loc := #caller_location) {
	if !ret {
		fmt.eprintln(loc, "SDL_ERROR:", sdl.GetError())
		os.exit(1)
	}
}

vk_assert :: proc(result: vk.Result, msg: string = "", loc := #caller_location) {
	if result != .SUCCESS {
		fmt.eprintln(loc, "VK_ERROR:", msg)
		os.exit(1)
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

pick_physical_device :: proc(
	instance: vk.Instance,
	surface: vk.SurfaceKHR,
) -> (
	vk.PhysicalDevice,
	int,
	int,
) {
	device_count: u32
	vk.EnumeratePhysicalDevices(instance, &device_count, nil)

	devices := make([]vk.PhysicalDevice, device_count)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices))

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

		surface_format_count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &surface_format_count, nil)

		surface_present_mode_count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			surface,
			&surface_present_mode_count,
			nil,
		)


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
			vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(index), surface, &present_support)

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

main :: proc() {
	sdl_assert(sdl.Init({.VIDEO}))

	when ODIN_OS == .Darwin {
		sdl_assert(
			sdl.Vulkan_LoadLibrary(
				"./MoltenVK/Package/Latest/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib",
			),
		)
		defer sdl.Vulkan_UnloadLibrary() // I don't know how "when" scopes work
	}

	window := sdl.CreateWindow("DrawDraw", 800, 600, {.VULKAN})
	sdl_assert(window != nil)

	vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))


	if CHECK_VALIDATION_LAYERS && !check_validation_layer_support() {
		fmt.eprintln("validation layers requested, but not available!")
		os.exit(1)
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

	// TODO: Add `VK_EXT_DEBUG_UTILS_EXTENSION_NAME` when the validation layers are enabled
	instance_create_info.ppEnabledExtensionNames = sdl.Vulkan_GetInstanceExtensions(
		&instance_create_info.enabledExtensionCount,
	)

	if instance_create_info.ppEnabledExtensionNames == nil {
		log.panic("Failed to get required extensions from SDL")
	}

	for i in 0 ..< instance_create_info.enabledExtensionCount {
		fmt.println("Extension:", instance_create_info.ppEnabledExtensionNames[i])
	}

	debug_utils_messenger_create_info: vk.DebugUtilsMessengerCreateInfoEXT

	if CHECK_VALIDATION_LAYERS {
		// TODO: Add the validation layers debug callback
	} else {
		instance_create_info.enabledLayerCount = 0
		instance_create_info.pNext = nil
	}

	instance: vk.Instance
	vk_assert(
		vk.CreateInstance(&instance_create_info, nil, &instance),
		"failed to create instance!",
	)
	defer vk.DestroyInstance(instance, nil)

	vk.load_proc_addresses_instance(instance)

	surface: vk.SurfaceKHR
	sdl_assert(sdl.Vulkan_CreateSurface(window, instance, nil, &surface))
	defer sdl.Vulkan_DestroySurface(instance, surface, nil)

	p_device, graphic_family, present_family := pick_physical_device(instance, surface)
	if p_device == nil {
		log.panic("Failed to find a suitable GPU")
	}

	unique_queue_families := []int{graphic_family, present_family}

	queue_create_info_count := int(graphic_family != present_family) + 1
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
		enabledLayerCount       = 0, // TODO: validation layers
	}

	device: vk.Device
	vk_assert(
		vk.CreateDevice(p_device, &device_create_info, nil, &device),
		"failed to create logical device",
	)
	defer vk.DestroyDevice(device, nil)

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
