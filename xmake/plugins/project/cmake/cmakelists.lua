--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        cmakelists.lua
--

-- imports
import("core.project.project")
import("core.tool.compiler")
import("core.base.semver")
import("core.project.rule")
import("lib.detect.find_tool")
import("private.utils.batchcmds")

-- get minimal cmake version
function _get_cmake_minver()
    local cmake_minver = _g.cmake_minver
    if not cmake_minver then
        local cmake = find_tool("cmake", {version = true})
        if cmake and cmake.version then
            cmake_minver = semver.new(cmake.version)
        end
        if not cmake_minver or cmake_minver:gt("3.15.0") then
            cmake_minver = semver.new("3.15.0")
        end
        _g.cmake_minver = cmake_minver
    end
    return cmake_minver
end

-- get unix path
function _get_unix_path(filepath)
    if path.is_absolute(filepath) and filepath:startswith(os.projectdir()) then
        filepath = path.relative(filepath, os.projectdir())
    end
    filepath = path.translate(filepath):gsub('\\', '/')
    return os.args(filepath)
end

-- get unix path relative to the cmake path
-- @see https://github.com/xmake-io/xmake/issues/2026
function _get_unix_path_relative_to_cmake(filepath)
    filepath = _get_unix_path(filepath)
    if filepath and not path.is_absolute(filepath) then
        filepath = "${CMAKE_SOURCE_DIR}/" .. filepath
    end
    return os.args(filepath)
end

-- get enabled languages from targets
function _get_project_languages(targets)
    local languages = {}
    for _, target in table.orderpairs(targets) do
        for _, sourcekind in ipairs(target:sourcekinds()) do
            if     sourcekind == "cc"  then table.insert(languages, "C")
            elseif sourcekind == "cxx" then table.insert(languages, "CXX")
            elseif sourcekind == "as"  then table.insert(languages, "ASM")
            elseif sourcekind == "cu"  then table.insert(languages, "CUDA")
            end
        end
    end
    languages = table.unique(languages)
    return languages
end

-- get configs from target
function _get_configs_from_target(target, name)
    local values = {}
    if name:find("flags", 1, true) then
        table.join2(values, target:toolconfig(name))
    end
    table.join2(values, target:get(name))
    table.join2(values, target:get_from_opts(name))
    table.join2(values, target:get_from_pkgs(name))
    table.join2(values, target:get_from_deps(name, {interface = true}))
    if not name:find("flags", 1, true) then -- for includedirs, links ..
        table.join2(values, target:toolconfig(name))
    end
    return table.unique(values)
end

-- add project info
function _add_project(cmakelists, languages)

    local cmake_version = _get_cmake_minver()
    cmakelists:print([[# this is the build file for project %s
# it is autogenerated by the xmake build system.
# do not edit by hand.
]], project.name() or "")
    cmakelists:print("# project")
    cmakelists:print("cmake_minimum_required(VERSION %s)", cmake_version)
    if cmake_version:ge("3.15.0") then
        -- for MSVC_RUNTIME_LIBRARY
        cmakelists:print("cmake_policy(SET CMP0091 NEW)")
    end
    local project_name = project.name()
    if not project_name then
        for _, target in table.orderpairs(project.targets()) do
            project_name = target:name()
            break
        end
    end
    if project_name then
        local project_info = ""
        local project_version = project.version()
        if project_version then
            project_info = project_info .. " VERSION " .. project_version
        end
        if languages then
            cmakelists:print("project(%s%s LANGUAGES %s)", project_name, project_info, table.concat(languages, " "))
        else
            cmakelists:print("project(%s%s)", project_name, project_info)
        end
    end
    cmakelists:print("")
end

-- add target: phony
function _add_target_phony(cmakelists, target)
    cmakelists:printf("add_custom_target(%s", target:name())
    local deps = target:get("deps")
    if deps then
        cmakelists:write(" DEPENDS")
        for _, dep in ipairs(deps) do
            cmakelists:write(" " .. dep)
        end
    end
    cmakelists:print(")")
    cmakelists:print("")
end

-- add target: binary
function _add_target_binary(cmakelists, target)
    cmakelists:print("add_executable(%s \"\")", target:name())
    cmakelists:print("set_target_properties(%s PROPERTIES OUTPUT_NAME \"%s\")", target:name(), target:basename())
    cmakelists:print("set_target_properties(%s PROPERTIES RUNTIME_OUTPUT_DIRECTORY \"%s\")", target:name(), _get_unix_path_relative_to_cmake(target:targetdir()))
end

-- add target: static
function _add_target_static(cmakelists, target)
    cmakelists:print("add_library(%s STATIC \"\")", target:name())
    cmakelists:print("set_target_properties(%s PROPERTIES OUTPUT_NAME \"%s\")", target:name(), target:basename())
    cmakelists:print("set_target_properties(%s PROPERTIES ARCHIVE_OUTPUT_DIRECTORY \"%s\")", target:name(), _get_unix_path_relative_to_cmake(target:targetdir()))
end

-- add target: shared
function _add_target_shared(cmakelists, target)
    cmakelists:print("add_library(%s SHARED \"\")", target:name())
    cmakelists:print("set_target_properties(%s PROPERTIES OUTPUT_NAME \"%s\")", target:name(), target:basename())
    if target:is_plat("windows") then
        -- @see https://github.com/xmake-io/xmake/issues/2192
        cmakelists:print("set_target_properties(%s PROPERTIES RUNTIME_OUTPUT_DIRECTORY \"%s\")", target:name(), _get_unix_path_relative_to_cmake(target:targetdir()))
        cmakelists:print("set_target_properties(%s PROPERTIES ARCHIVE_OUTPUT_DIRECTORY \"%s\")", target:name(), _get_unix_path_relative_to_cmake(target:targetdir()))
    else
        cmakelists:print("set_target_properties(%s PROPERTIES LIBRARY_OUTPUT_DIRECTORY \"%s\")", target:name(), _get_unix_path_relative_to_cmake(target:targetdir()))
    end
end

-- add target: headeronly
function _add_target_headeronly(cmakelists, target)
    cmakelists:print("add_library(%s INTERFACE)", target:name())
end

-- add target dependencies
function _add_target_dependencies(cmakelists, target)
    local deps = target:get("deps")
    if deps then
        cmakelists:printf("add_dependencies(%s", target:name())
        for _, dep in ipairs(deps) do
            cmakelists:write(" " .. dep)
        end
        cmakelists:print(")")
    end
end

-- add target sources
function _add_target_sources(cmakelists, target)
    local has_cuda = false
    cmakelists:print("target_sources(%s PRIVATE", target:name())
    for _, sourcebatch in table.orderpairs(target:sourcebatches()) do
        local sourcekind = sourcebatch.sourcekind
        if sourcekind == "cc" or sourcekind == "cxx" or sourcekind == "as" or sourcekind == "cu" then
            for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                cmakelists:print("    " .. _get_unix_path(sourcefile))
            end
        end
        if sourcekind == "cu" then
            has_cuda = true
        end
    end
    for _, headerfile in ipairs(target:headerfiles()) do
        cmakelists:print("    " .. _get_unix_path(headerfile))
    end
    cmakelists:print(")")
    if has_cuda then
        cmakelists:print("set_target_properties(%s PROPERTIES CUDA_SEPARABLE_COMPILATION ON)", target:name())
        local devlink = target:values("cuda.build.devlink")
        if devlink ~= nil then
            cmakelists:print("set_target_properties(%s PROPERTIES CUDA_RESOLVE_DEVICE_SYMBOLS %s)", target:name(), devlink and "ON" or "OFF")
        end
    end
end

-- add target source groups
-- @see https://github.com/xmake-io/xmake/issues/1149
function _add_target_source_groups(cmakelists, target)
    local filegroups = target:get("filegroups")
    for _, filegroup in ipairs(filegroups) do
        local files = target:extraconf("filegroups", filegroup, "files") or "**"
        local mode = target:extraconf("filegroups", filegroup, "mode")
        local rootdir = target:extraconf("filegroups", filegroup, "rootdir")
        assert(rootdir, "please set root directory, e.g. add_filegroups(%s, {rootdir = 'xxx'})", filegroup)
        local sources = {}
        local recurse_sources = {}
        if path.is_absolute(rootdir) then
            rootdir = _get_unix_path(rootdir)
        else
            rootdir = string.format("${CMAKE_CURRENT_SOURCE_DIR}/%s", _get_unix_path(rootdir))
        end
        for _, filepattern in ipairs(files) do
            if filepattern:find("**", 1, true) then
                filepattern = filepattern:gsub("%*%*", "*")
                table.insert(recurse_sources, _get_unix_path(path.join(rootdir, filepattern)))
            else
                table.insert(sources, _get_unix_path(path.join(rootdir, filepattern)))
            end
        end
        if #sources > 0 then
            cmakelists:print("FILE(GLOB %s_GROUP_SOURCE_LIST %s)", target:name(), table.concat(sources, " "))
            if mode and mode == "plain" then
                cmakelists:print("source_group(%s FILES ${%s_GROUP_SOURCE_LIST})",
                    _get_unix_path(filegroup), target:name())
            else
                cmakelists:print("source_group(TREE %s PREFIX %s FILES ${%s_GROUP_SOURCE_LIST})",
                    rootdir, _get_unix_path(filegroup), target:name())
            end
        end
        if #recurse_sources > 0 then
            cmakelists:print("FILE(GLOB_RECURSE %s_GROUP_RECURSE_SOURCE_LIST %s)", target:name(), table.concat(recurse_sources, " "))
            if mode and mode == "plain" then
                cmakelists:print("source_group(%s FILES ${%s_GROUP_RECURSE_SOURCE_LIST})",
                    _get_unix_path(filegroup), target:name())
            else
                cmakelists:print("source_group(TREE %s PREFIX %s FILES ${%s_GROUP_RECURSE_SOURCE_LIST})",
                    rootdir, _get_unix_path(filegroup), target:name())
            end
        end
    end
end

-- add target precompilied header
function _add_target_precompiled_header(cmakelists, target)
    local precompiled_header = target:get("pcheader") or target:get("pcxxheader")
    if precompiled_header then
        cmakelists:print("target_precompile_headers(%s PRIVATE", target:name())
        cmakelists:print("    $<$<COMPILE_LANGUAGE:%s>:${CMAKE_CURRENT_SOURCE_DIR}/%s>",
            target:get("pcxxheader") and "CXX" or "C",
            _get_unix_path(precompiled_header))
        cmakelists:print(")")
    end
end

-- add target include directories
function _add_target_include_directories(cmakelists, target)
    local includedirs = _get_configs_from_target(target, "includedirs")
    if #includedirs > 0 then
        cmakelists:print("target_include_directories(%s PRIVATE", target:name())
        for _, includedir in ipairs(includedirs) do
            cmakelists:print("    " .. _get_unix_path(includedir))
        end
        cmakelists:print(")")
    end

    -- TODO deprecated
    local includedirs_interface = target:get("includedirs", {interface = true})
    if includedirs_interface then
        cmakelists:print("target_include_directories(%s INTERFACE", target:name())
        for _, headerdir in ipairs(includedirs_interface) do
            cmakelists:print("    " .. _get_unix_path(headerdir))
        end
        cmakelists:print(")")
    end
    -- export config header directory (deprecated)
    local configheader = target:configheader()
    if configheader then
        cmakelists:print("target_include_directories(%s PUBLIC %s)", target:name(), _get_unix_path(path.directory(configheader)))
    end
end

-- add target system include directories
-- we disable system/external includes first, because cmake doesn’t seem to be able to support msvc /external:I
-- https://github.com/xmake-io/xmake/issues/1050
function _add_target_sysinclude_directories(cmakelists, target)
    local includedirs = _get_configs_from_target(target, "sysincludedirs")
    if #includedirs > 0 then
        -- TODO should be `SYSTEM PRIVATE`
        cmakelists:print("target_include_directories(%s PRIVATE", target:name())
        for _, includedir in ipairs(includedirs) do
            cmakelists:print("    " .. _get_unix_path(includedir))
        end
        cmakelists:print(")")
    end
    local includedirs_interface = target:get("sysincludedirs", {interface = true})
    if includedirs_interface then
        cmakelists:print("target_include_directories(%s INTERFACE", target:name())
        for _, headerdir in ipairs(includedirs_interface) do
            cmakelists:print("    " .. _get_unix_path(headerdir))
        end
        cmakelists:print(")")
    end
end

-- add target compile definitions
function _add_target_compile_definitions(cmakelists, target)
    local defines = _get_configs_from_target(target, "defines")
    if #defines > 0 then
        cmakelists:print("target_compile_definitions(%s PRIVATE", target:name())
        for _, define in ipairs(defines) do
            cmakelists:print("    " .. define)
        end
        cmakelists:print(")")
    end
end

-- add target compile options
function _add_target_compile_options(cmakelists, target)
    local cflags   = _get_configs_from_target(target, "cflags")
    local cxflags  = _get_configs_from_target(target, "cxflags")
    local cxxflags = _get_configs_from_target(target, "cxxflags")
    local cuflags  = _get_configs_from_target(target, "cuflags")
    if #cflags > 0 or #cxflags > 0 or #cxxflags > 0 or #cuflags > 0 then
        cmakelists:print("target_compile_options(%s PRIVATE", target:name())
        for _, flag in ipairs(cflags) do
            cmakelists:print("    $<$<COMPILE_LANGUAGE:C>:" .. flag .. ">")
        end
        for _, flag in ipairs(cxflags) do
            cmakelists:print("    $<$<COMPILE_LANGUAGE:C>:" .. flag .. ">")
            cmakelists:print("    $<$<COMPILE_LANGUAGE:CXX>:" .. flag .. ">")
        end
        for _, flag in ipairs(cxxflags) do
            cmakelists:print("    $<$<COMPILE_LANGUAGE:CXX>:" .. flag .. ">")
        end
        for _, flag in ipairs(cuflags) do
            cmakelists:print("    $<$<COMPILE_LANGUAGE:CUDA>:" .. flag .. ">")
        end
        cmakelists:print(")")
    end
end

-- add target language standards
function _add_target_language_standards(cmakelists, target)
    local cstds =
    {
        c89         = "90"
    ,   gnu89       = "90" -- TODO add cflags -std=gnu90 if supported
    ,   c99         = "99"
    ,   gnu99       = "99" -- TODO
    ,   c11         = "11"
    ,   gnu11       = "11" -- TODO
    }
    local cxxstds =
    {
        cxx98       = "98"
    ,   gnuxx98     = "98" -- TODO
    ,   cxx11       = "11"
    ,   gnuxx11     = "11"
    ,   cxx14       = "14"
    ,   gnuxx14     = "14"
    ,   cxx17       = "17"
    ,   gnuxx17     = "17"
    ,   cxx1z       = "17"
    ,   gnuxx1z     = "17"
    ,   cxx2a       = "20"
    ,   gnuxx2a     = "20"
    }
    for _, lang in ipairs(target:get("languages")) do
        local cstd = cstds[lang]
        if cstd then
            cmakelists:print("set_property(TARGET %s PROPERTY C_STANDARD %s)", target:name(), cstd)
            if cstd == "99" or cstd == "11" then
                cmakelists:print("if(MSVC)")
                cmakelists:print("    target_compile_options(%s PRIVATE $<$<COMPILE_LANGUAGE:C>:-TP>)", target:name())
                cmakelists:print("endif()")
            end
        end
        local cxxstd = cxxstds[lang]
        if cxxstd then
            cmakelists:print("set_property(TARGET %s PROPERTY CXX_STANDARD %s)", target:name(), cxxstd)
        end
    end
end

-- add target warnings
function _add_target_warnings(cmakelists, target)
    local flags_gcc =
    {
        none     = "-w"
    ,   less     = "-Wall"
    ,   more     = "-Wall"
    ,   all      = "-Wall"
    ,   allextra = "-Wall -Wextra"
    ,   error    = "-Werror"
    }
    local flags_msvc =
    {
        none     = "-W0"
    ,   less     = "-W1"
    ,   more     = "-W3"
    ,   all      = "-W3" -- = "-Wall" will enable too more warnings
    ,   allextra = "-W4"
    ,   error    = "-WX"
    }
    local warnings = target:get("warnings")
    if warnings then
        cmakelists:print("if(MSVC)")
        for _, warn in ipairs(warnings) do
            cmakelists:print("    target_compile_options(%s PRIVATE %s)", target:name(), flags_msvc[warn])
        end
        cmakelists:print("else()")
        for _, warn in ipairs(warnings) do
            cmakelists:print("    target_compile_options(%s PRIVATE %s)", target:name(), flags_gcc[warn])
        end
        cmakelists:print("endif()")
    end
end

-- add target languages
function _add_target_languages(cmakelists, target)
    local features =
    {
        c89   = "c_std_90"
    ,   c99   = "c_std_99"
    ,   c11   = "c_std_11"
    ,   cxx98 = "cxx_std_98"
    ,   cxx11 = "cxx_std_11"
    ,   cxx14 = "cxx_std_14"
    ,   cxx17 = "cxx_std_17"
    ,   cxx20 = "cxx_std_20"
    ,   cxxlatest = "cxx_std_23"
    }
    local languages = target:get("languages")
    if languages then
        for _, lang in ipairs(languages) do
            local feature = features[lang] or (features[lang:replace("++", "xx")])
            if feature then
                cmakelists:print("target_compile_features(%s PRIVATE %s)", target:name(), feature)
            end
        end
    end
end

-- add target optimization
function _add_target_optimization(cmakelists, target)
    local flags_gcc =
    {
        none       = "-O0"
    ,   fast       = "-O1"
    ,   faster     = "-O2"
    ,   fastest    = "-O3"
    ,   smallest   = "-Os"
    ,   aggressive = "-Ofast"
    }
    local flags_msvc =
    {
        none        = "$<$<CONFIG:Debug>:-Od>"
    ,   faster      = "$<$<CONFIG:Release>:-O2>"
    ,   fastest     = "$<$<CONFIG:Release>:-Ox -fp:fast>"
    ,   smallest    = "$<$<CONFIG:Release>:-O1>"
    ,   aggressive  = "$<$<CONFIG:Release>:-Ox -fp:fast>"
    }
    local optimization = target:get("optimize")
    if optimization then
        cmakelists:print("if(MSVC)")
        cmakelists:print("    target_compile_options(%s PRIVATE %s)", target:name(), flags_msvc[optimization])
        cmakelists:print("else()")
        cmakelists:print("    target_compile_options(%s PRIVATE %s)", target:name(), flags_gcc[optimization])
        cmakelists:print("endif()")
    end
end

-- add target vs runtime
--
-- https://github.com/xmake-io/xmake/issues/1661#issuecomment-927979489
-- https://cmake.org/cmake/help/latest/prop_tgt/MSVC_RUNTIME_LIBRARY.html
--
function _add_target_vs_runtime(cmakelists, target)
    local cmake_minver = _get_cmake_minver()
    if cmake_minver:ge("3.15.0") then
        local vs_runtime = target:get("runtimes")
        if not vs_runtime then
            vs_runtime = "MT"
        end
        cmakelists:print("if(MSVC)")
        if vs_runtime:startswith("MT") then
            vs_runtime = "MultiThreaded$<$<CONFIG:Debug>:Debug>"
        elseif vs_runtime:startswith("MD") then
            vs_runtime = "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL"
        end
        cmakelists:print('    set_property(TARGET %s PROPERTY', target:name())
        cmakelists:print('        MSVC_RUNTIME_LIBRARY "%s")', vs_runtime)
        cmakelists:print("endif()")
    end
end

-- add target link libraries
function _add_target_link_libraries(cmakelists, target)

    -- add links
    local links      = _get_configs_from_target(target, "links")
    local syslinks   = _get_configs_from_target(target, "syslinks")
    local frameworks = _get_configs_from_target(target, "frameworks")
    if #frameworks > 0 then
        for _, framework in ipairs(frameworks) do
            table.insert(links, "\"-framework " .. framework .. "\"")
        end
    end
    table.join2(links, syslinks)
    if #links > 0 then
        cmakelists:print("target_link_libraries(%s PRIVATE", target:name())
        for _, link in ipairs(links) do
            cmakelists:print("    " .. link)
        end
        cmakelists:print(")")
    end
end

-- add target link directories
function _add_target_link_directories(cmakelists, target)
    local linkdirs = _get_configs_from_target(target, "linkdirs")
    if #linkdirs > 0 then
        local cmake_minver = _get_cmake_minver()
        if cmake_minver:ge("3.13.0") then
            cmakelists:print("target_link_directories(%s PRIVATE", target:name())
            for _, linkdir in ipairs(linkdirs) do
                cmakelists:print("    " .. _get_unix_path(linkdir))
            end
            cmakelists:print(")")
        else
            cmakelists:print("if(MSVC)")
            cmakelists:print("    target_link_libraries(%s PRIVATE", target:name())
            for _, linkdir in ipairs(linkdirs) do
                cmakelists:print("        -libpath:" .. _get_unix_path(linkdir))
            end
            cmakelists:print("    )")
            cmakelists:print("else()")
            cmakelists:print("    target_link_libraries(%s PRIVATE", target:name())
            for _, linkdir in ipairs(linkdirs) do
                cmakelists:print("        -L" .. _get_unix_path(linkdir))
            end
            cmakelists:print("    )")
            cmakelists:print("endif()")
        end
    end
end

-- add target link options
function _add_target_link_options(cmakelists, target)
    local ldflags = _get_configs_from_target(target, "ldflags")
    local shflags = _get_configs_from_target(target, "shflags")
    if #ldflags > 0 or #shflags > 0 then
        local flags = {}
        for _, flag in ipairs(table.unique(table.join(ldflags, shflags))) do
            if target:linker():has_flags(flag) then
                table.insert(flags, flag)
            end
        end
        if #flags > 0 then
            local cmake_minver = _get_cmake_minver()
            if cmake_minver:ge("3.13.0") then
                cmakelists:print("target_link_options(%s PRIVATE", target:name())
            else
                cmakelists:print("target_link_libraries(%s PRIVATE", target:name())
            end
            for _, flag in ipairs(flags) do
                cmakelists:print("    " .. flag)
            end
            cmakelists:print(")")
        end
    end
end

-- get command string
function _get_command_string(cmd)
    local kind = cmd.kind
    local opt = cmd.opt
    if cmd.program then
        -- @see https://github.com/xmake-io/xmake/discussions/2156
        local argv = {}
        for _, v in ipairs(table.join(cmd.program, cmd.argv)) do
            if path.is_absolute(v) then
                v = _get_unix_path_relative_to_cmake(v)
            end
            table.insert(argv, v)
        end
        local command = os.args(argv)
        if opt and opt.curdir then
            command = "${CMAKE_COMMAND} -E chdir " .. _get_unix_path_relative_to_cmake(opt.curdir) .. " " .. command
        end
        return command
    elseif kind == "cp" then
        if os.isdir(cmd.srcpath) then
            return string.format("${CMAKE_COMMAND} -E copy_directory %s %s",
                _get_unix_path_relative_to_cmake(cmd.srcpath), _get_unix_path_relative_to_cmake(cmd.dstpath))
        else
            return string.format("${CMAKE_COMMAND} -E copy %s %s",
                _get_unix_path_relative_to_cmake(cmd.srcpath), _get_unix_path_relative_to_cmake(cmd.dstpath))
        end
    elseif kind == "rm" then
        return string.format("${CMAKE_COMMAND} -E rm -rf %s", _get_unix_path_relative_to_cmake(cmd.filepath))
    elseif kind == "mv" then
        return string.format("${CMAKE_COMMAND} -E rename %s %s",
            _get_unix_path_relative_to_cmake(cmd.srcpath), _get_unix_path_relative_to_cmake(cmd.dstpath))
    elseif kind == "cd" then
        return string.format("cd %s", _get_unix_path_relative_to_cmake(cmd.dir))
    elseif kind == "mkdir" then
        return string.format("${CMAKE_COMMAND} -E make_directory %s", _get_unix_path_relative_to_cmake(cmd.dir))
    elseif kind == "show" then
        return string.format("echo %s", cmd.showtext)
    end
end

-- add custom command
function _add_target_custom_command(cmakelists, target, command, suffix)
    if suffix == "before" then
        -- ADD_CUSTOM_COMMAND and PRE_BUILD did not work as I expected,
        -- so we need use add_dependencies and fake target to support it.
        --
        -- @see https://gitlab.kitware.com/cmake/cmake/-/issues/17802
        --
        local key = target:name() .. "_" .. hash.uuid():split("-", {plain = true})[1]
        cmakelists:print("add_custom_command(OUTPUT output_%s", key)
        cmakelists:print("    COMMAND %s", command)
        cmakelists:print("    VERBATIM")
        cmakelists:print(")")
        cmakelists:print("add_custom_target(target_%s", key)
        cmakelists:print("    DEPENDS output_%s", key)
        cmakelists:print(")")
        cmakelists:print("add_dependencies(%s target_%s)", target:name(), key)
    else
        cmakelists:print("add_custom_command(TARGET %s", target:name())
        if suffix == "after" then
            cmakelists:print("    POST_BUILD")
        end
        cmakelists:print("    COMMAND %s", command)
        cmakelists:print("    VERBATIM")
        cmakelists:print(")")
    end
end

-- add target custom commands for target
function _add_target_custom_commands_for_target(cmakelists, target, suffix)
    for _, ruleinst in ipairs(target:orderules()) do
        local scriptname = "buildcmd" .. (suffix and ("_" .. suffix) or "")
        local script = ruleinst:script(scriptname)
        if script then
            local batchcmds_ = batchcmds.new({target = target})
            script(target, batchcmds_, {})
            if not batchcmds_:empty() then
                for _, cmd in ipairs(batchcmds_:cmds()) do
                    local command = _get_command_string(cmd)
                    if command then
                        _add_target_custom_command(cmakelists, target, command, suffix)
                    end
                end
            end
        end
    end
end

-- add target custom commands for object rules
function _add_target_custom_commands_for_objectrules(cmakelists, target, sourcebatch, suffix)

    -- get rule
    local rulename = assert(sourcebatch.rulename, "unknown rule for sourcebatch!")
    local ruleinst = assert(project.rule(rulename) or rule.rule(rulename), "unknown rule: %s", rulename)

    -- generate commands for xx_buildcmd_files
    local scriptname = "buildcmd_files" .. (suffix and ("_" .. suffix) or "")
    local script = ruleinst:script(scriptname)
    if script then
        local batchcmds_ = batchcmds.new({target = target})
        script(target, batchcmds_, sourcebatch, {})
        if not batchcmds_:empty() then
            for _, cmd in ipairs(batchcmds_:cmds()) do
                local command = _get_command_string(cmd)
                if command then
                    _add_target_custom_command(cmakelists, target, command, suffix)
                end
            end
        end
    end

    -- generate commands for xx_buildcmd_file
    if not script then
        scriptname = "buildcmd_file" .. (suffix and ("_" .. suffix) or "")
        script = ruleinst:script(scriptname)
        if script then
            local sourcekind = sourcebatch.sourcekind
            for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                local batchcmds_ = batchcmds.new({target = target})
                script(target, batchcmds_, sourcefile, {})
                if not batchcmds_:empty() then
                    for _, cmd in ipairs(batchcmds_:cmds()) do
                        local command = _get_command_string(cmd)
                        if command then
                            _add_target_custom_command(cmakelists, target, command, suffix)
                        end
                    end
                end
            end
        end
    end
end

-- add target custom commands
function _add_target_custom_commands(cmakelists, target)
    _add_target_custom_commands_for_target(cmakelists, target, "before")
    for _, sourcebatch in table.orderpairs(target:sourcebatches()) do
        local sourcekind = sourcebatch.sourcekind
        if sourcekind ~= "cc" and sourcekind ~= "cxx" and sourcekind ~= "as" then
            _add_target_custom_commands_for_objectrules(cmakelists, target, sourcebatch, "before")
            _add_target_custom_commands_for_objectrules(cmakelists, target, sourcebatch)
            _add_target_custom_commands_for_objectrules(cmakelists, target, sourcebatch, "after")
        end
    end
    _add_target_custom_commands_for_target(cmakelists, target, "after")
end

-- TODO export target headers (deprecated)
function _export_target_headers(target)
    local srcheaders, dstheaders = target:headers()
    if srcheaders and dstheaders then
        local i = 1
        for _, srcheader in ipairs(srcheaders) do
            local dstheader = dstheaders[i]
            if dstheader then
                os.cp(srcheader, dstheader)
            end
            i = i + 1
        end
    end
end

-- add target
function _add_target(cmakelists, target)

    -- add comment
    cmakelists:print("# target")

    -- is phony target?
    local targetkind = target:kind()
    if target:is_phony() then
        return _add_target_phony(cmakelists, target)
    elseif targetkind == "binary" then
        _add_target_binary(cmakelists, target)
    elseif targetkind == "static" then
        _add_target_static(cmakelists, target)
    elseif targetkind == "shared" then
        _add_target_shared(cmakelists, target)
    elseif targetkind == 'headeronly' then
        _add_target_headeronly(cmakelists, target)
        _add_target_include_directories(cmakelists, target)
        return
    else
        raise("unknown target kind %s", target:kind())
    end

    -- TODO export target headers (deprecated)
    _export_target_headers(target)

    -- add target dependencies
    _add_target_dependencies(cmakelists, target)

    -- add target precompilied header
    _add_target_precompiled_header(cmakelists, target)

    -- add target include directories
    _add_target_include_directories(cmakelists, target)

    -- add target system include directories
    _add_target_sysinclude_directories(cmakelists, target)

    -- add target compile definitions
    _add_target_compile_definitions(cmakelists, target)

    -- add target language standards
    _add_target_language_standards(cmakelists, target)

    -- add target compile options
    _add_target_compile_options(cmakelists, target)

    -- add target warnings
    _add_target_warnings(cmakelists, target)

    -- add target languages
    _add_target_languages(cmakelists, target)

    -- add target optimization
    _add_target_optimization(cmakelists, target)

    -- add vs runtime for msvc
    _add_target_vs_runtime(cmakelists, target)

    -- add target link libraries
    _add_target_link_libraries(cmakelists, target)

    -- add target link directories
    _add_target_link_directories(cmakelists, target)

    -- add target link options
    _add_target_link_options(cmakelists, target)

    -- add target custom commands
    _add_target_custom_commands(cmakelists, target)

    -- add target sources
    _add_target_sources(cmakelists, target)

    -- add target source groups
    _add_target_source_groups(cmakelists, target)

    -- end
    cmakelists:print("")
end

-- generate cmakelists
function _generate_cmakelists(cmakelists)

    -- add project info
    _add_project(cmakelists, _get_project_languages(project.targets()))

    -- add targets
    for _, target in table.orderpairs(project.targets()) do
        _add_target(cmakelists, target)
    end
end

-- make
function make(outputdir)

    -- enter project directory
    local oldir = os.cd(os.projectdir())

    -- open the cmakelists
    local cmakelists = io.open(path.join(outputdir, "CMakeLists.txt"), "w")

    -- generate cmakelists
    _generate_cmakelists(cmakelists)

    -- close the cmakelists
    cmakelists:close()

    -- leave project directory
    os.cd(oldir)
end
