--[[
    Grabber is a tool for Garry's Mod that allows archivists to scrape entire GitHub repositories for archiving or research purposes.
    The user can add a GitHub repo, run a command to download the repo to a specified location in their data/ folder,
    and from there inspect or use the files as they please after they are archived to the data/ folder.

    For legal reasons, information gathered using Grabber (this script et al.) may not be used for spamming purposes, including
    for the purposes of sending unsolicited emails to GitHub users or selling what GitHub defines as "User Personal Information."

    Run 'grabber help' to see commands, including: 
        add (to add repositories),
        targets (to see release tags and branches you can tell grabber to download),
        download (to download repositories), 
        delete (to remove unwanted repositories).

    Set the convar 'grabber_download_unstable_code' to 1 if you want to download the default branch, not the latest release
    tag, by default.
        Pro: May be receiving the latest changes before a new release is defined.
        Con: Latest code may be unstable.
]]

local string = string
local f = string.format
local tonumber = tonumber
local file = file
local http = http

-- Detect a hot reload...
local isReloading = false
local oldRepositories
if grabber then
    isReloading = true
    oldRepositories = grabber.Repositories
end

-- Represents different steps in the download process. IDLE means no download is happening.
local STEP = {
    IDLE = 0,
    TARGETS = 1,
    RESOLVE = 2,
    FILES = 3
}

grabber = {
    Version = 0,
    ConVars = {
        DownloadUnstableCode = CreateClientConVar("grabber_download_unstable_code", "0", true, false, "If true, Grabber will pull from the master branch instead of the latest release. Code may be more up-to-date but less stable without a proper release tag.")
    },
    Repositories = { --[[ Add after InitPostEntity with grabber.AddRepository! ]] },
    Status = {}, -- transient
    UIStore = {
        -- StatusButton: Button at the top of the frame which should be updated with the current status.
        Colors = {
            ErrorButton = Color(107, 5, 4), -- #6B0504
            ErrorPrint = Color(255, 155, 155),
            OKButton = Color(193, 211, 127), -- #C1D37F
            OKPrint = Color(255, 255, 255),
            UIDarkLine = Color(0, 0, 0, 50),
            UILightLine = Color(255, 255, 255, 25),
        },
        StatusText = "Nothing to report",
        TagColor = 23,
        TagColors = {
            [0] = Color( 255, 25, 25 ),
            [1] = Color( 255, 90, 25 ),
            [2] = Color( 255, 155, 25 ),
            [3] = Color( 255, 220, 25 ),
            [4] = Color( 255, 255, 25 ),
            [5] = Color( 220, 255, 25 ),
            [6] = Color( 155, 255, 25 ),
            [7] = Color( 90, 255, 25 ),
            [8] = Color( 25, 255, 25 ),
            [9] = Color( 25, 255, 90 ),
            [10] = Color( 25, 255, 155 ),
            [11] = Color( 25, 255, 220 ),
            [12] = Color( 25, 255, 255 ),
            [13] = Color( 25, 220, 255 ),
            [14] = Color( 25, 155, 255 ),
            [15] = Color( 25, 90, 255 ),
            [16] = Color( 25, 25, 255 ),
            [17] = Color( 90, 25, 255 ),
            [18] = Color( 155, 25, 255 ),
            [19] = Color( 220, 25, 255 ),
            [20] = Color( 225, 25, 255 ),
            [21] = Color( 225, 25, 220 ),
            [22] = Color( 225, 25, 155 ),
            [23] = Color( 225, 25, 90 ),
        },
    },
}

grabber.Error = function(s, repoName)
    grabber.Status[repoName] = STEP.IDLE
    grabber.UIStore.TagColor = (grabber.UIStore.TagColor + 1) % 24
    MsgC(grabber.UIStore.TagColors[grabber.UIStore.TagColor], f("[Grabber/%s/Error] ", repoName), grabber.UIStore.Colors.ErrorPrint, s, color_white, "\n")
    if IsValid(grabber.UIStore.StatusButton) then
        grabber.UIStore.StatusText = f('[%s] %s', repoName, s)
        grabber.UIStore.StatusButton:SetText(grabber.UIStore.StatusText)
    end
end
grabber.Print = function(s, repoName)
    grabber.UIStore.TagColor = (grabber.UIStore.TagColor + 1) % 24
    MsgC(grabber.UIStore.TagColors[grabber.UIStore.TagColor], f("[Grabber/%s] ", repoName), grabber.UIStore.Colors.OKPrint, s, color_white, "\n")
    if IsValid(grabber.UIStore.StatusButton) then
        grabber.UIStore.StatusText = f('[%s] %s', repoName, s)
        grabber.UIStore.StatusButton:SetText(grabber.UIStore.StatusText)
    end
end

-- If reloading, repositories are restored under the creation of the ConCommand at the bottom of the file


-- =============================
-- Helpers
-- =============================

-- File extensions that the download command knows Garry's Mod allows. If a file is extensionless or has an illegal
-- extension, the file will be written with a .txt extension tacked onto the end of its filename.
local ALLOWED_EXTENSIONS = {
    txt = true,
    dat = true,
    json = true,
    xml = true,
    csv = true,
    jpg = true,
    jpeg = true,
    png = true,
    vtf = true,
    vmt = true,
    mp3 = true,
    wav = true,
    ogg = true,
}

-- Used with the 'update' command. If the user tries to edit something like downloadedVersion that isn't in this whitelist,
-- it won't actually update anything.
local ALLOWED_UPDATE_PROPERTIES = {
    name = true,
    userName = true,
    projectName = true,
    defaultBranchName = true,
    dataFolderSubDirectory = true,
}

-- Alias for http.Fetch that redirects to grabber.Error upon error.
local fetch = function(url, success)
    http.Fetch(url, success, grabber.Error, {})
end

-- Adds .txt to the end of a filename from GitHub if we're not allowed to save it with the original extension.
local normalizeFilePath = function(filePath)
    local dotPos = filePath:find(".", -6, true)
    if (not dotPos) or not ALLOWED_EXTENSIONS[filePath:sub(dotPos + 1)] then
        return f("%s.txt", filePath)
    end
    return filePath
end

-- Replace HTML-escaped decimal &#stuff; with their represented characters
local unescapeHTMLString = function(str)
    for s in string.gmatch(str, "&#(%d+);") do
        str = string.Replace(str, f("&#%s;", s), string.char(tonumber(s)))
    end
    return str
end

-- Returns false if str is a "string" type with nonzero length after a .Trim().
local isEmpty = function(str)
    if type(str) ~= "string" or string.Trim(str) == "" then
        return true
    end
    return false
end

-- Returns URL to GitHub page containing scrapable branch data.
local getBranchPageURL = function(repo)
    -- e.g. https://github.com/tjb2640/winesweeper/branches/all
    return f("https://github.com/%s/%s/branches/all", repo.userName, repo.projectName)
end

-- Returns base URL for fetching info from a directory tree element.
local getBaseTreeURL = function(repo, target)
    return f("https://github.com/%s/%s/tree/%s", repo.userName, repo.projectName, target)
end

-- Returns URL to GitHub page containing scrapable tag data.
local getTagPageURL = function(repo)
    -- e.g. https://github.com/MagnumMacKivler/RLCPT2/tags
    return f("https://github.com/%s/%s/tags", repo.userName, repo.projectName)
end

-- Returns a github.com file url's raw content counterpart.
local getRawURL = function(url)
    local rawUrl = string.Replace(url, "github.com", "raw.githubusercontent.com")
    rawUrl = string.Replace(rawUrl, "tree/", "")
    rawUrl = string.Replace(rawUrl, "&amp;", "&")
    return string.Replace(unescapeHTMLString(rawUrl), " ", "%20")
end


-- =============================
-- Internal stuff
-- =============================


-- (internal) Step 3 of the repo download process - actually downloads files and saves them in their places
local _downloadFiles = function(repo, target)
    grabber.Status[repo.name] = STEP.FILES
    grabber.Print(f("Grabbing %s (%s/%s) @ %s", repo.name, repo.userName, repo.projectName, target), repo.name)
    
    local workerCount = 0
    local baseUrl = getBaseTreeURL(repo, target)
    local timerName = f("CheckDownloadComplete_%s_%s", repo.name, target)

    local handleError = function(e)
        workerCount = workerCount - 1
        grabber.Error(e, repo.name)
    end

    timer.Create(timerName, 1, 0, function()
        -- Status will be nil if the panic button on the GUI is hit. 
        -- Keep it clean and remove the timer if so. TODO: don't save files or report errors if a download was canceled.
        if workerCount == 0 or grabber.Status[repo.name] == nil then 
            grabber.Status[repo.name] = STEP.IDLE
            timer.Remove(timerName)
            -- Reopen the GUI if it's open. It's set to delete on remove so we can use IsValid to check if it's open.
            if (IsValid(grabber.UIStore.GUI)) then
                grabber.ShowGUI()
            end
            grabber.Print("Finished downloading.", repo.name)
        end
    end)

    local downloadFetch
    downloadFetch = function(url)
        -- always increment this at the start of the function so we know if there are pending fetches
        -- (these occur in async, one after the other)
        workerCount = workerCount + 1

        -- Start by performing a fetch to URL.
        http.Fetch(string.Replace(f("%s/%s", baseUrl, url), " ", "%20"), function(body, size, headers, code)
            local foundPaths = {}

            local lines = string.Explode("\n", body) -- consider delimiting in the match instead.
            for i = 1, #lines do
                local line = lines[i]
                -- Search this line in the body for links to either files or directories in the repo.
                if line:find("js-navigation-open", 1, true) then
                    -- Found a link, probably, classify under isFile
                    local isFile = line:find("/blob/", 1, true) ~= nil
                    -- Matches the name of the file or directory
                    local pathName = line:match(".*>(.*)</a>")
                    if pathName then
                        -- Github will condense multiple empty nested dirs within a span/ before the final child.
                        local collapsedBefore = string.TrimRight(line, "</span>"):match(".*>(.*)</span>")
                        if collapsedBefore then
                            pathName = f("%s%s", collapsedBefore, pathName)
                        end
                        table.insert(foundPaths, {
                            type = isFile and "blob" or "tree",
                            path = url == "" and pathName or f("%s/%s", url, pathName)
                        })
                    end
                end
            end

            -- Do we have any paths? Send them through downloadFetch() with their path as the URL.
            -- Are there any files? We want to download them (which is another http.Fetch)
            if #foundPaths > 0 then
                for i = 1, #foundPaths do
                    local t = foundPaths[i].type
                    local p = foundPaths[i].path
                    
                    -- if we're saving into a subdirectory (or a few of them) in the data dir, we need to compensate
                    -- for that setting:
                    local filePath = p
                    if repo.dataFolderSubDirectory then
                        if not file.IsDir(repo.dataFolderSubDirectory, "DATA") then
                            file.CreateDir(repo.dataFolderSubDirectory)
                        end
                        filePath = f('%s/%s', repo.dataFolderSubDirectory, p)
                    end

                    if t == "tree" then
                        -- Create the directory if it is mid
                        if not file.IsDir(filePath, "DATA") then
                            file.CreateDir(filePath)
                        end
                        -- And also crawl this new dir
                        downloadFetch(p)
                    elseif t == "blob" then
                        -- Make an HTTP.Fetch request and download the file.
                        -- This should count towards total worker count.
                        local rawUrl = getRawURL(f("%s/%s", baseUrl, p))
                        workerCount = workerCount + 1
                        grabber.Print(f("  ➔ GET %s", rawUrl), repo.name)
                        http.Fetch(rawUrl, function(body, size, headers, code)
                            if (code == 200) and body then
                                file.Write(normalizeFilePath(unescapeHTMLString(filePath)), body)
                            else
                                handleError(f("HTTP Code %d for %s", code, rawUrl))
                            end
                            workerCount = workerCount - 1
                        end, handleError, {})

                    end
                end
            end

            -- Set the repo's last downloaded version to the chosen target (branch or tag)
            repo.downloadedVersion = target
            grabber.SaveRepositories()
            -- Finally we need to decrement the number of workerCount since this worker is done :)
            workerCount = workerCount - 1

        end, handleError, {}) -- end http.Fetch
    end

    -- Start the download
    downloadFetch("")
end

-- (internal) step 2 of the download process - resolves an appropriate branch or tag name to download.
local _getDesiredTarget = function(repo, branchOrTag, validReleases)
    grabber.Status[repo.name] = STEP.RESOLVE
    -- validReleases should contain keys keyed using branchOrTag if branchOrTag is defined
    -- if branchOrTag is not defined, fall back to the latest tag, OR the repo's main branch if unstable is wanted
    local branchOrTag = branchOrTag or (grabber.ConVars.DownloadUnstableCode:GetInt() == 1 and repo.defaultBranchName or validReleases[1].tag)

    -- Check that this is a valid target - the releases table will contain all the branches as well.
    for i = 1, #validReleases do
        if validReleases[i].tag == branchOrTag then
            return _downloadFiles(repo, branchOrTag)
        end
    end

    grabber.Error(f("Branch or tag '%s' not found in repo '%s'", branchOrTag, repo.name), repo.name)
end

-- (internal) step 1 of the download process - discovers the given GitHub project's release tags and branch names.
local _discoverTags = function(repoName, branchOrTag)
    grabber.Status[repoName] = STEP.TARGETS
    local callback = function(releases)
        _getDesiredTarget(grabber.Repositories[repoName], branchOrTag, releases)
    end
    grabber.DiscoverTargets(repoName, callback)
end

-- Do a few bookkeeping things InitPostEntity:
-- 1. Make the grabber-meta folder in data/.
-- 2. Save a blank grabber-meta/repositories.txt file if there is not one there already.
-- 3. Load any repositories from the above file.
--
-- Coders wanting to call grabber.AddRepository directly should do it in the next frame in IPE
-- (create your own InitPostEntity hook and call grabber.AddRepository within a timer.Simple(0) callback)
hook.Add("InitPostEntity", "Grabber_InitPostEntity_LoadRepositories", function()
    if not file.IsDir("grabber-meta", "DATA") then
        file.CreateDir("grabber-meta")
    end
    
    if not file.Exists("grabber-meta/repositories.txt", "DATA") then
        file.Write("grabber-meta/repositories.txt", util.TableToJSON({}))
    end

    grabber.LoadRepositoriesFromDisk()
end)

-- Hook into clientside chat, if the text is !grabber we want to hide it from everyone's chatbox, and then if ply is LocalPlayer(), open the GUI.
hook.Add("OnPlayerChat", "Grabber_OnPlayerChat_OpenGrabberMenu", function(ply, text, teamChat, isDead)
    if string.lower(text) == "!grabber" then
        if ply == LocalPlayer() then
            grabber.ShowGUI()
        end
        return true -- suppress !grabber commands for everyone
    end
end)


-- =============================
-- Grabber API
-- =============================


-- Users can also add their own repositories through the UI.
-- userName: Username of the github account hosting the repo (or fork).
-- projectName: Name of the project.
-- defaultBranchName (="master"): Default unstable branch to download if no target is provided, and unstable downloads are enabled.
-- dataFolderSubDirectory (=""): Subdirectory within the data/ folder to save the repo's files to. Can be a tree/like/this.
grabber.AddRepository = function(repoName, userName, projectName, defaultBranchName, dataFolderSubDirectory)
    local repoName = string.lower(repoName)
    local repo = {
        name = repoName,
        userName = userName,
        projectName = projectName,
        defaultBranchName = defaultBranchName or "master",
        dataFolderSubDirectory = dataFolderSubDirectory or nil,
        downloadedVersion = "?"
    }

    -- Retain downloadedVersion data from the old repository if we're updating it, and if the files for the "new" repo are being
    -- pointed to the same dataFolderSubDirectory as the "old" one. (QoS)
    if grabber.Repositories[repoName] then
        if repo.dataFolderSubDirectory == grabber.Repositories[repoName].dataFolderSubDirectory then
            repo.downloadedVersion = grabber.Repositories[repoName].downloadedVersion or "?"
        end
        grabber.Repositories[repoName] = repo
        grabber.Print(f("Repository '%s' (%s/%s) updated.", repoName, userName, projectName), repoName)
        return
    end

    grabber.Repositories[repoName] = repo
    grabber.SaveRepositories()
    grabber.Print(f("Repository '%s' (%s/%s) added.", repoName, userName, projectName), repoName)
end

-- Force-closes the GUI if it is open.
grabber.CloseGUI = function()
    if IsValid(grabber.UIStore.GUI) then
        grabber.UIStore.GUI:Close()
        grabber.UIStore.GUI:Remove()
        grabber.UIStore.GUI = nil
    end
end

-- Deletes a repository given its repo name.
grabber.DeleteRepository = function(repoName)
    if grabber.Repositories[repoName] then
        grabber.Repositories[repoName] = nil
        grabber.Status[repoName] = nil
        grabber.SaveRepositories()
        grabber.Print(f("Deleted repository '%s'", repoName), repoName)
        timer.Simple(0, function()
            grabber.ShowGUI(true)
        end)
        return
    end
    grabber.Error(f("Repository with name '%s' does not exist", repoName), repoName)
end

-- Downloads a GitHub project based on the repo indexed with the given repoName, and targeting the branch name
-- or tag given with branchOrTag.
-- Returns nothing, everything is done in async within http.Fetch onSuccess callbacks.
-- The status of a download can be retrieved by getting grabber.Status[repoName], which will be nil OR a status value in the STEP table.
grabber.DownloadRepository = function(repoName, branchOrTag)
    grabber.Status[repoName] = grabber.Status[repoName] or STEP.IDLE

    if grabber.Status[repoName] ~= STEP.IDLE then
        grabber.Print(f("Grabber is already downloading repository '%s', please wait for it to finish", repoName), repoName)
        return
    end

    if not grabber.Repositories[repoName] then
        grabber.Error(f("Repository with name '%s' not added yet", repoName), repoName)
        return
    end

    -- Discover tags. (Stuff gets chained from result closures from there on out)
    _discoverTags(repoName, branchOrTag)
end

-- Returns a table containing release tags and branch names that it discovers via scraping the GitHub page for the repo.
-- Since this needs to run HTTP calls, it will pass the result back via the provided callback and not directly return it.
grabber.DiscoverTargets = function(repoName, callback)
    local repo = grabber.Repositories[repoName]
    if not repo then callback({}) end

    fetch(getTagPageURL(repo), function(body, size, headers, code)
        if code ~= 200 then
            grabber.Error(f("Status code != 200: %d", code), repoName)
        end
        local blines = string.Explode("\n", body)
        local releases = {} -- tag, date, commit
        for i = 1, #blines do
            local line = blines[i]
            local tagNameMatch = line:match("/releases/tag/(.*)\" data")
            if tagNameMatch then
                table.insert(releases, {
                    tag = tagNameMatch,
                    kind = "release",
                    date = "(none)",
                    commit = "(none)",
                })
            end
            
            local dateMatch = line:match(">(.*)</relative%-time>")
            if dateMatch then
                (releases[#releases] or {}).date = dateMatch
            end

            local commitMatch = line:match("/commit/(.*)\">")
            if commitMatch then
                (releases[#releases] or {}).commit = commitMatch
            end
        end
    
        -- We have all the tags, now grab all the branches
        fetch(getBranchPageURL(repo), function(body, size, headers, code)
            local lines = string.Explode('\n', body)
            for i = 1, #lines do
                local line = lines[i]
                local matches = {line:match("<a class=\"branch%-name.*>(.*)</a>")}
                if #matches > 0 then
                    table.insert(releases, {
                        tag = matches[1],
                        kind = "branch",
                        date = "(none)",
                        commit = "(none)"
                    })
                end
            end

            -- Pass the tags+branches we found back to the implementing function
            callback(releases)
        end) -- end branch fetch
    end) -- end tag fetch
end

-- Prints a table to console.
-- Abstracted for future use but currently only used in the 'targets' command.
grabber.FormatPrintedTable = function(name, headers, keys, lengths, values)
    -- Create a line format
    local template = "| "
    for i = 1, #lengths do
        template = string.format("%s %s |", template, string.format("%%-%ds", lengths[i]))
    end
    
    -- Print the header
    local header = string.format(template, unpack(headers))
    grabber.Print(header, name, true)
    grabber.Print(string.rep("-", #header), name, true)
    
    -- For each of the values, print their lines
    for i = 1, #values do
        local value = values[i]
        local props = {}
        for j = 1, #keys do
            table.insert(props, value[keys[j]] or "(none)")
        end
        grabber.Print(string.format(template, unpack(props)), name, true)
    end
end

-- Loads repositories from the disk (grabber-meta/repositories.txt)
grabber.LoadRepositoriesFromDisk = function()
    -- Don't totally replace grabber.Repositories, but add to it from the disk.
    -- If some repo on the disk is already in the Lua table, prefer the disk's version.
    if file.Exists("grabber-meta/repositories.txt", "DATA") then
        local content = file.Read("grabber-meta/repositories.txt", "DATA")
        if content then
            local repos = util.JSONToTable(content)
            for repoName, info in next, repos, nil do
                grabber.Repositories[repoName] = table.Copy(info)
            end
        end
    end
end

-- Saves repositories to the disk (grabber-meta/repositories.txt)
grabber.SaveRepositories = function()
    if not file.IsDir("grabber-meta", "DATA") then
        file.CreateDir("grabber-meta")
    end
    file.Write("grabber-meta/repositories.txt", util.TableToJSON(grabber.Repositories))
end

-- Main window GUI code goes here. Also see grabber.ShowAddRepoGUI, grabber.ListTargetsGUI
grabber.ShowGUI = function(onlyShowIfOpen)
    if onlyShowIfOpen then
        if not IsValid(grabber.UIStore.GUI) then
            return
        end
    end
    grabber.CloseGUI()
    local window = vgui.Create("DFrame")
    window:SetDeleteOnClose(true)
    window:SetSize(600, 600)
    window:SetTitle("Grabber GUI")
    window:Center()
    window:MakePopup()
    grabber.UIStore.GUI = window

    local frame = vgui.Create("DPanel", window)
    frame.Paint = function() end
    frame:Dock(FILL)
    frame:DockPadding(8, 8, 8, 8)

    frame.top = vgui.Create("DPanel", frame)
    frame.top:SetSize(1, 24)
    frame.top:Dock(TOP)
    frame.top.Paint = function() end
    frame.top.cli_propaganda = vgui.Create("DLabel", frame.top)
    frame.top.cli_propaganda:SetText("TIP: You can also use grabber in the console! Type 'grabber help' for more info.")
    frame.top.cli_propaganda:Dock(FILL)

    -- "Repositories:" text and add/delete buttons
    frame.repo_options_pane = vgui.Create("DPanel", frame)
    frame.repo_options_pane:SetSize(1, 32)
    frame.repo_options_pane:DockPadding(4, 4, 4, 4)
    frame.repo_options_pane.Paint = function() end
    frame.repo_options_pane:Dock(TOP)

    frame.repo_options_pane.repos_label = vgui.Create("DLabel", frame.repo_options_pane)
    frame.repo_options_pane.repos_label:SetText("Repositories:")
    frame.repo_options_pane.repos_label:SetFont("Trebuchet24")
    frame.repo_options_pane.repos_label:SizeToContents()
    frame.repo_options_pane.repos_label:Dock(LEFT)

    frame.repo_options_pane.delete_button = vgui.Create("DButton", frame.repo_options_pane)
    frame.repo_options_pane.delete_button:SetText("Delete repo")
    frame.repo_options_pane.delete_button:SetSize(72, 32)
    frame.repo_options_pane.delete_button:Dock(RIGHT)
    function frame.repo_options_pane.delete_button:DoClick()
        Derma_StringRequest(
            "Delete a repo", 
            "Type a repo name to delete it. Careful! If you delete a repo \nyou'll have to manually add it again if you want it back.\n" ..
                "Deleting a repo does not delete or revert any files in your \ndata folder, it just removes the repo from the repo list.",
            "",
            function(text)
                if grabber.Repositories[text] then
                    grabber.DeleteRepository(text)
                end
            end,
            function(text) end,
            "!! DELETE !!",
            "Go back..."
        )
    end

    frame.repo_options_pane.add_button = vgui.Create("DButton", frame.repo_options_pane)
    frame.repo_options_pane.add_button:SetText("Add repo")
    frame.repo_options_pane.add_button:SetSize(72, 32)
    frame.repo_options_pane.add_button:Dock(RIGHT)
    function frame.repo_options_pane.add_button:DoClick()
        grabber.ShowAddRepoGUI()
    end

    -- Add custom panels for each repo added to Grabber.
    frame.repo_list = vgui.Create("DScrollPanel", frame)
    frame.repo_list:Dock(FILL)
    for repoName, repo in next, grabber.Repositories, nil do
        local panel = vgui.Create("DPanel")
        panel:SetSize(1, 32)
        panel:DockPadding(16, 4, 4, 4)
        function panel:Paint(w, h)
            surface.SetDrawColor(grabber.UIStore.Colors.UIDarkLine)
            surface.DrawLine(8, 0, w-4, 0)
            surface.SetDrawColor(grabber.UIStore.Colors.UILightLine)
            surface.DrawLine(8, 1, w-4, 1)
        end

        panel.repo_name_label = vgui.Create("DLabel", panel)
        panel.repo_name_label:SetFont("Trebuchet18")
        panel.repo_name_label:SetText(f("%s  ", repoName))
        panel.repo_name_label:SizeToContents()
        panel.repo_name_label:Dock(LEFT)

        panel.repo_detail_label = vgui.Create("DLabelURL", panel)
        panel.repo_detail_label:SetURL(f("https://github.com/%s/%s", repo.userName, repo.projectName))
        panel.repo_detail_label:SetText(f("(%s/%s)", repo.userName, repo.projectName))
        panel.repo_detail_label:SetSize(256, 1)
        panel.repo_detail_label:Dock(FILL)

        frame.repo_options_pane.download_button = vgui.Create("DButton", panel)
        frame.repo_options_pane.download_button:SetText("Download")
        frame.repo_options_pane.download_button:SetSize(72, 32)
        frame.repo_options_pane.download_button:Dock(RIGHT)
        function frame.repo_options_pane.download_button:DoClick()
            if grabber.Status[repoName] == STEP.IDLE or grabber.Status[repoName] == nil then
                grabber.ShowDownloadGUI(repoName)
            end
        end
        function frame.repo_options_pane.download_button:DoRightClick()
            if grabber.Status[repoName] == STEP.IDLE or grabber.Status[repoName] == nil then
                Derma_StringRequest(
                    "Request custom target", 
                    "Type a custom branch name or release tag to download for this repository.",
                    "",
                    function(text)
                        if grabber.Status[repoName] == STEP.IDLE or grabber.Status[repoName] == nil then
                            grabber.ShowDownloadGUI(repoName, text)
                        end
                    end,
                    function(text) end,
                    "Download",
                    "Cancel"
                )
            end
        end

        panel.repo_version_label = vgui.Create("DLabel", panel)
        panel.repo_version_label:SetText(f("Downloaded: %s  ", repo.downloadedVersion == "?" and "Not downloaded" or repo.downloadedVersion))
        panel.repo_version_label:SizeToContents()
        panel.repo_version_label:Dock(RIGHT)
        
        frame.repo_list:AddItem(panel)
        panel:Dock(TOP)
    end

    frame.status_panel = vgui.Create("DPanel", frame)
    frame.status_panel:SetSize(1, 36)
    frame.status_panel:Dock(BOTTOM)

    frame.status_panel.status_text = vgui.Create("DButton", frame.status_panel)
    grabber.UIStore.StatusButton = frame.status_panel.status_text
    frame.status_panel.status_text:SetMultiline(true)
    frame.status_panel.status_text:SetText(grabber.UIStore.StatusText)
    frame.status_panel.status_text:DockPadding(24, 24, 24, 24)
    frame.status_panel.status_text:Dock(FILL)

    frame.use_unstable_checkbox = vgui.Create("DCheckBoxLabel", frame)
    frame.use_unstable_checkbox:SetConVar("grabber_download_unstable_code")
    frame.use_unstable_checkbox:SetText("Download unstable code (latest branch) by default, instead of latest release?")
    frame.use_unstable_checkbox:Dock(BOTTOM)
    frame.use_unstable_checkbox:SizeToContents()

    function frame.status_panel.status_text:DoClick()
        Derma_Query(
            "Forcefully mark all current grabber downloads as invalid?\n(This is useful if they get stuck for some reason)",
            "Panic!",
            "Yes (invalidate downloads)", function()
                grabber.Status = {}
                grabber.Print("Current downloads force-invalidated.", "GUI")
            end,
            "No", function() end)
    end
end

grabber.ShowAddRepoGUI = function()
    local window = vgui.Create("DFrame")
    window:SetDeleteOnClose(true)
    window:SetSize(400, 250)
    window:SetTitle("Grabber GUI - Add GitHub repository")
    window:Center()
    window:MakePopup()
    grabber.UIStore.GUI_Add = window

    local valid = {
        userName = false,
        projectName = false,
        repoName = false,
        defaultBranch = true, -- currently always true
        dataDirSubDir = true, -- allows empty input, so start true
    }

    local values = {
        userName = "",
        projectName = "",
        repoName = "",
        defaultBranch = "",
        dataDirSubDir = "",
    }

    local frame = vgui.Create("DPanel", window)
    frame.Paint = function() end
    frame:Dock(FILL)
    frame:DockPadding(8, 8, 8, 8)

    -- Title
    frame.top = vgui.Create("DPanel", frame)
    frame.top:SetSize(1, 24)
    frame.top:Dock(TOP)
    frame.top.Paint = function() end
    frame.top.cli_propaganda = vgui.Create("DLabel", frame.top)
    frame.top.cli_propaganda:SetText("Enter new repo information here.")
    frame.top.cli_propaganda:Dock(FILL)

    -- GitHub URL:
    frame.github_link_line = vgui.Create("DPanel", frame)
    frame.github_link_line:Dock(TOP)
    frame.github_link_line:DockPadding(8, 8, 8, 8)
    frame.github_link_line:SetSize(1, 32)
    frame.github_link_line.Paint = function() end
    frame.github_link_line.label = vgui.Create("DLabel", frame.github_link_line)
    frame.github_link_line.label:SetText("GitHub URL: ")
    frame.github_link_line.label:Dock(LEFT)
    frame.github_link_line.label:SizeToContents()
    frame.github_link_line.text_entry = vgui.Create("DTextEntry", frame.github_link_line)
    frame.github_link_line.text_entry:Dock(FILL)
    frame.github_link_line.text_entry:SetUpdateOnType(true)
    frame.github_link_line.text_entry:SetPlaceholderText("https://github.com/userName/projectName")
    -- Validation
    function frame.github_link_line.text_entry:OnValueChange(value)
        -- Allow no www., and www.
        local userName, projectName = value:match("https://github%.com/([%w%d%-_]+)/([%w%d%-_%.]+)/*")
        if userName == nil then
            userName, projectName = value:match("https://www.github%.com/([%w%d%-_]+)/([%w%d%-_%.]+)/*")
        end

        -- Both should validate at the same time.
        if userName ~= nil and projectName ~= nil then
            valid.userName = true
            valid.projectName = true
            frame.github_link_line.validated_image_panel.image:SetImage("icon16/accept.png")
        else
            valid.userName = false
            valid.projectName = false
            frame.github_link_line.validated_image_panel.image:SetImage("icon16/cross.png")
        end

        values.userName = userName
        values.projectName = projectName
    end
    frame.github_link_line.validated_image_panel = vgui.Create("DPanel", frame.github_link_line)
    frame.github_link_line.validated_image_panel:SetSize(24, 16)
    frame.github_link_line.validated_image_panel.Paint = function() end
    frame.github_link_line.validated_image_panel:Dock(RIGHT)
    frame.github_link_line.validated_image_panel:SetTooltip("Must be a valid URL pointing to a GitHub repo.\nhttps://github.com/userName/projectName")
    frame.github_link_line.validated_image_panel.image = vgui.Create("DImage", frame.github_link_line.validated_image_panel)
    frame.github_link_line.validated_image_panel.image:SetImage("icon16/cross.png")
    frame.github_link_line.validated_image_panel.image:SetSize(16, 16)
    frame.github_link_line.validated_image_panel.image:Dock(RIGHT)

    -- Repo name:
    frame.repo_name_line = vgui.Create("DPanel", frame)
    frame.repo_name_line:Dock(TOP)
    frame.repo_name_line:DockPadding(8, 8, 8, 8)
    frame.repo_name_line:SetSize(1, 32)
    frame.repo_name_line.Paint = function() end
    frame.repo_name_line.label = vgui.Create("DLabel", frame.repo_name_line)
    frame.repo_name_line.label:SetText("Repo name: ")
    frame.repo_name_line.label:Dock(LEFT)
    frame.repo_name_line.label:SizeToContents()
    frame.repo_name_line.text_entry = vgui.Create("DTextEntry", frame.repo_name_line)
    frame.repo_name_line.text_entry:Dock(FILL)
    frame.repo_name_line.text_entry:SetUpdateOnType(true)
    frame.repo_name_line.text_entry:SetPlaceholderText("myname")
    -- Validation
    function frame.repo_name_line.text_entry:OnValueChange(value)
        local matched = value:match("[%w%d%-_]+")
        if matched == value and not grabber.Repositories[value] then
            valid.repoName = true
            frame.repo_name_line.validated_image_panel.image:SetImage("icon16/accept.png")
        else
            valid.repoName = false
            frame.repo_name_line.validated_image_panel.image:SetImage("icon16/cross.png")
        end

        values.repoName = value
    end
    frame.repo_name_line.validated_image_panel = vgui.Create("DPanel", frame.repo_name_line)
    frame.repo_name_line.validated_image_panel:SetSize(24, 16)
    frame.repo_name_line.validated_image_panel.Paint = function() end
    frame.repo_name_line.validated_image_panel:Dock(RIGHT)
    frame.repo_name_line.validated_image_panel:SetTooltip("Must be a single word with letters, numbers, dashes or underscores only.\nMust be unique, cannot be shared with other repos already added.")
    frame.repo_name_line.validated_image_panel.image = vgui.Create("DImage", frame.repo_name_line.validated_image_panel)
    frame.repo_name_line.validated_image_panel.image:SetImage("icon16/cross.png")
    frame.repo_name_line.validated_image_panel.image:SetSize(16, 16)
    frame.repo_name_line.validated_image_panel.image:Dock(RIGHT)

    frame.branch_line = vgui.Create("DPanel", frame)
    frame.branch_line:Dock(TOP)
    frame.branch_line:DockPadding(8, 8, 8, 8)
    frame.branch_line:SetSize(1, 32)
    frame.branch_line.Paint = function() end
    frame.branch_line.label = vgui.Create("DLabel", frame.branch_line)
    frame.branch_line.label:SetText("Default unstable branch: ")
    frame.branch_line.label:Dock(LEFT)
    frame.branch_line.label:SizeToContents()
    frame.branch_line.text_entry = vgui.Create("DTextEntry", frame.branch_line)
    frame.branch_line.text_entry:Dock(FILL)
    frame.branch_line.text_entry:SetUpdateOnType(true)
    frame.branch_line.text_entry:SetPlaceholderText("master")
    frame.branch_line.text_entry:SetValue("master")
    -- No validation, trust the user (sweating) - just cache the branch name.
    function frame.branch_line.text_entry:OnValueChange(value)
        values.defaultBranch = isEmpty(value) and "master" or value
    end
    
    frame.savedir_line = vgui.Create("DPanel", frame)
    frame.savedir_line:Dock(TOP)
    frame.savedir_line:DockPadding(8, 8, 8, 8)
    frame.savedir_line:SetSize(1, 32)
    frame.savedir_line.Paint = function() end
    frame.savedir_line.label = vgui.Create("DLabel", frame.savedir_line)
    frame.savedir_line.label:SetText("Data folder subfolder: ")
    frame.savedir_line.label:Dock(LEFT)
    frame.savedir_line.label:SizeToContents()
    frame.savedir_line.text_entry = vgui.Create("DTextEntry", frame.savedir_line)
    frame.savedir_line.text_entry:Dock(FILL)
    frame.savedir_line.text_entry:SetUpdateOnType(true)
    frame.savedir_line.text_entry:SetPlaceholderText("expression2 (can be blank or/any/amount)")
    -- Validation
    function frame.savedir_line.text_entry:OnValueChange(value)
        local matched = value:match("[%w%d%-_%./']+")
        if isEmpty(value) or matched == value then
            valid.dataDirSubDir = true
            frame.savedir_line.validated_image_panel.image:SetImage("icon16/accept.png")
        else
            valid.dataDirSubDir = false
            frame.savedir_line.validated_image_panel.image:SetImage("icon16/cross.png")
        end

        values.dataDirSubDir = not isEmpty(value) and value or nil
    end
    frame.savedir_line.validated_image_panel = vgui.Create("DPanel", frame.savedir_line)
    frame.savedir_line.validated_image_panel:SetSize(24, 16)
    frame.savedir_line.validated_image_panel.Paint = function() end
    frame.savedir_line.validated_image_panel:Dock(RIGHT)
    frame.savedir_line.validated_image_panel:SetTooltip("Must not contain characters that the filesystem cannot handle.")
    frame.savedir_line.validated_image_panel.image = vgui.Create("DImage", frame.savedir_line.validated_image_panel)
    frame.savedir_line.validated_image_panel.image:SetImage("icon16/accept.png")
    frame.savedir_line.validated_image_panel.image:SetSize(16, 16)
    frame.savedir_line.validated_image_panel.image:Dock(RIGHT)

    frame.add_button = vgui.Create("DButton", frame)
    frame.add_button:SetText("Add")
    frame.add_button:SetSize(72, 32)
    frame.add_button:Dock(BOTTOM)
    function frame.add_button:DoClick()
        -- local userName, projectName, repoName, defaultBranch, dataDirSubDir
        PrintTable(valid)
        if valid.userName and valid.projectName and valid.repoName and valid.defaultBranch and valid.dataDirSubDir then
            if isEmpty(values.defaultBranch) then values.defaultBranch = "master" end
            if isEmpty(values.dataDirSubDir) then values.dataDirSubDir = nil end
            grabber.AddRepository(values.repoName, values.userName, values.projectName, values.defaultBranch, values.dataDirSubDir)
            timer.Simple(0, function()
                grabber.ShowGUI(true)
            end)
            window:Close()
        else
            Derma_Message("You must fix the form validation errors before continuing.", "Form errors", "OK")
        end
    end
end

-- Will fetch the latest tag for the repoName and prompt the user if they'd like to download
grabber.ShowDownloadGUI = function(repoName, customTarget)
    local window = vgui.Create("DFrame")
    window:SetSize(300, 150)
    window:SetDeleteOnClose(true)
    window:SetTitle(f("Downloading repo '%s'", repoName))
    window:MakePopup()
    window:Center()

    local frame = vgui.Create("DPanel", window)
    frame:DockPadding(8, 8, 8, 8)
    frame:Dock(FILL)
    frame.Paint = function() end

    frame.status_label = vgui.Create("DLabel", frame)
    frame.status_label:SetText("Fetching repo information...")
    frame.status_label:Dock(TOP)
    frame.status_label:SetWrap(true)

    frame.bottom_panel = vgui.Create("DPanel", frame)
    frame.bottom_panel:SetSize(1, 32)
    frame.bottom_panel.Paint = function() end
    frame.bottom_panel:Dock(BOTTOM)

    frame.bottom_panel.cancel_button = vgui.Create("DButton", frame.bottom_panel)
    frame.bottom_panel.cancel_button:SetText("Cancel")
    frame.bottom_panel.cancel_button:Dock(RIGHT)
    function frame.bottom_panel.cancel_button:DoClick()
        window:Close()
    end

    frame.bottom_panel.download_button = vgui.Create("DButton", frame.bottom_panel)
    frame.bottom_panel.download_button:SetText("Download")
    frame.bottom_panel.download_button:Dock(RIGHT)
    frame.bottom_panel.download_button:Hide()

    grabber.DiscoverTargets(repoName, function(targets)
        if #targets == 0 then
            frame.status_label:SetText(f("No targets available for '%s'.\nMaybe the repo doesn't actually exist.", repoName))
            return
        end

        local wantedBranch
        local repo = grabber.Repositories[repoName]

        -- Would have been requested from the right-click popup for the Download button.
        if customTarget ~= nil then
            for i = 1, #targets do
                local target = targets[i]
                if target.tag == customTarget then
                    wantedBranch = customTarget
                    break
                end
            end
            if wantedBranch == nil then
                local errorText = f("Sorry, there is no branch or release tag named '%s' in the repository added under '%s'.\nYou can try these instead:\n\n", customTarget, repoName)
                for i = 1, #targets do
                    errorText = f("%s\n - %s", errorText, targets[i].tag)
                end
                frame.status_label:SetText(errorText)
                frame.status_label:SizeToContents()
                local labelHeight = select(2, frame.status_label:GetSize())
                local windowHeight = select(2, window:GetSize())
                -- Resize the window if there's an overflow of branch/tag names.
                if windowHeight < labelHeight + 64 then
                    window:SetSize(300, math.min(ScrH() - 128, labelHeight + 64))
                    window:Center()
                end
                return
            end
        else -- Just find the latest branch or target, depending on whether or not the user wants unstable code.
            if grabber.ConVars.DownloadUnstableCode:GetInt() == 1 then 
                for i = 1, #targets do
                    local target = targets[i]
                    if target.kind == "branch" and target.tag == repo.defaultBranchName then
                        wantedBranch = repo.defaultBranchName
                        break
                    end
                end
            end

            -- Will pass if the unstable is enabled and the unstable branch couldn't resolve as well as if it's disabled. (QoS)
            wantedBranch = wantedBranch or targets[1].tag
        end

        -- Display different text if the user's download branch and the latest are the same.
        if wantedBranch ~= repo.downloadedVersion then
            frame.status_label:SetText(f("Current version: %s\nVersion to download: %s\nProceed?", repo.downloadedVersion, wantedBranch))
        else
            frame.status_label:SetText(f("The current version you have downloaded and the latest are the same (%s)\nRedownload this version anyway?", wantedBranch))
        end
        frame.status_label:SizeToContents()

        -- Activate the download button.
        frame.bottom_panel.download_button.DoClick = function(self)
            window:Close()
            grabber.DownloadRepository(repoName, wantedBranch)
        end
        frame.bottom_panel.download_button:Show()
    end)
end


-- =============================
-- ConCommand
-- =============================


-- Callbacks for the concommand :)
local operations = {
    help = function(repoName, branchOrTag)
        grabber.Print("List of commands:", "Help", true)
        grabber.Print("  add [repoName] [author] [projectName] [defaultBranch='master'] [dataDirSubDir=''] - Adds a GitHub repo to grabber so it knows how to download it.", "Help", true)
        grabber.Print("  download [repoName] [branch/tag] - downloads the latest files for the repo. Branch/release tag is optional. See targets with 'grabber targets'.", "Help", true)
        grabber.Print("  targets [repoName] - lists release tags and branch names for the given repo name.", "Help", true)
        grabber.Print("", "Help", true)
        grabber.Print("Downloading the latest, but possibly unstable, code by default:", "Help", true)
        grabber.Print("  In your console, run:", "Help", true)
        grabber.Print("    grabber_download_unstable_code 1", "Help", true)
        grabber.Print("  This will tell grabber to download from the default branch instead of the latest release tag if you run 'grabber download' with no branch target.", "Help", true)
        grabber.Print("  Code on the default branch may be newer but may also be less stable than a release.", "Help", true)
        grabber.Print("  You can always override the default branch selection by passing the release tag or target name after the repo name in 'grabber download'.", "Help", true)
    end,
    add = function(repoName, author, projectName, defaultBranch, dataDirSubDir)
        -- basic empty validations
        if isEmpty(repoName) then
            grabber.Error("Repo name cannot be empty.", "add")
        elseif isEmpty(author) then
            grabber.Error("Author (GitHub display name) cannot be empty.", "add")
        elseif isEmpty(projectName) then
            grabber.Error("Project name cannot be empty.", "add")
        else
            grabber.AddRepository(repoName, author, projectName, defaultBranch, dataDirSubDir)
        end
    end,
    delete = function(repoName)
        if isEmpty(repoName) then
            grabber.Error("Repo name cannot be empty.", "delete")
        else
            grabber.DeleteRepository(repoName)
        end
    end,
    download = function(repoName, branchOrTag)
        if not grabber.Repositories[repoName] then
            grabber.Error(f("Repository '%s' has not yet been added.", repoName), repoName)
        else
            grabber.DownloadRepository(repoName, branchOrTag)
        end
    end,
    repos = function(repoName, branchOrTag)
        if table.Count(grabber.Repositories) == 0 then
            grabber.Print("No repos added. You can add some with 'grabber add' (Type 'grabber help' for help)", "repos", true)
            return
        end
        
        grabber.Print("List of available GitHub repositories (add more with 'grabber add')", "repos", true)
        for repoName, repo in next, grabber.Repositories, nil do
            grabber.Print(string.format(" %s @ %s  :: %s/%s :: Default unstable branch '%s' :: Downloads to 'data/%s'", 
                repoName, 
                repo.downloadedVersion,
                repo.userName, 
                repo.projectName,
                repo.defaultBranchName or "main",
                repo.dataFolderSubDirectory or ""), "repos", true)
        end
    end,
    targets = function(repoName, branchOrTag)
        if not grabber.Repositories[repoName] then
            grabber.Error(f("Repository '%s' has not yet been added.", repoName), repoName)
        else
            grabber.DiscoverTargets(repoName, function(releases)
                grabber.FormatPrintedTable(
                    string.format("%s - targets ('%s' on disk)", repoName, grabber.Repositories[repoName].downloadedVersion),
                    {"Name", "Type", "Release date",},
                    {"tag", "kind", "date",},
                    {32, 8, 13},
                    releases
                )
            end)
        end
    end,
}

-- Used below with the concommand.Add's autocomplete function.
local autocomplete_operation = {
    add = function(cmd, args, trail, argIndex)
        local BASE = f("%s add", cmd)
        local CMDS = {BASE}

        if argIndex >= 3 then
            table.insert(CMDS, "repoName")
        end

        if argIndex >= 4 then
            table.insert(CMDS, "userName")
        end

        if argIndex >= 5 then
            table.insert(CMDS, "githubRepoName")
        end

        if argIndex >= 6 then
            table.insert(CMDS, "defaultUnstableBranch=main")
        end

        if argIndex >= 7 then
            table.insert(CMDS, "defaultSaveDirectory=(blank)")
        end

        return {table.concat(CMDS, " ")}
    end,
    delete = function(cmd, args, trail, argIndex)
        local BASE = f("%s delete", cmd)
        local CMDS = {}

        -- list repositories (grabber delete X)
        if argIndex >= 3 then
            for repoName, _ in next, grabber.Repositories, nil do
                if trail[3] == nil or repoName:sub(1, #trail[3]) == trail[3] then
                    table.insert(CMDS, f("%s %s", BASE, repoName))
                end
            end
            return CMDS
        end

        return {BASE .. argIndex}
    end,
    download = function(cmd, args, trail, argIndex)
        local BASE = f("%s download", cmd)
        local CMDS = {}

        -- list repositories (grabber download X)
        if argIndex == 3 then
            for repoName, _ in next, grabber.Repositories, nil do
                if trail[3] == nil or repoName:sub(1, #trail[3]) == trail[3] then
                    table.insert(CMDS, f("%s %s", BASE, repoName))
                end
            end
            return CMDS
        end

        -- prompt for branch or tag (grabber download X <target>)
        if argIndex >= 4 then
            return {f("%s %s <tag_or_branch>", BASE, trail[3])}
        end

        return {BASE .. argIndex}
    end,
    help = function(cmd, args, trail, argIndex)
        local BASE = f("%s help", cmd)
        return {BASE}
    end,
    repos = function(cmd, args, trail, argIndex)
        local BASE = f("%s repos", cmd)
        return {BASE}
    end,
    targets = function(cmd, args, trail, argIndex)
        local BASE = f("%s targets", cmd)
        local CMDS = {}

        -- list repositories (grabber download X)
        if argIndex >= 3 then
            for repoName, _ in next, grabber.Repositories, nil do
                if trail[3] == nil or repoName:sub(1, #trail[3]) == trail[3] then
                    table.insert(CMDS, f("%s %s", BASE, repoName))
                end
            end
            return CMDS
        end

        return {BASE .. argIndex}
    end,
}

concommand.Add("grabber", function(ply, cmd, args)
    if not args[1] then
        grabber.ShowGUI()
    elseif not operations[args[1]] then
        grabber.Print(f("Operation '%s' not defined. Try running 'grabber help'.", (args[1] or "none")), "Main command")
    else
        operations[args[1]](args[2], args[3], args[4], args[5], args[6])
    end
end, function(cmd, args)
    -- Autocomplete function.
    local trail = {cmd}
    for s in string.gmatch(args, "[^%s]+") do
        table.insert(trail, s)
    end

    -- Get the index of the subcommand we want to run autocomplete for.
    -- If there's a space on the end of the last arg, display next index.
    local idx = #trail
    if args:sub(-1) == " " then
        idx = idx + 1
    end

    -- Should we hand off the autocomplete results to the proper operation?
    if #trail > 2 or (#trail >= 2 and (args:sub(-1) == " ")) then
        if autocomplete_operation[trail[2]] then
            return autocomplete_operation[trail[2]](cmd, args, trail, idx)
        end
        -- There is no command, the user is likely confused, display "help"
        return {f("%s help", cmd)}
    end 
    
    -- Or are we just looking for a command to run?
    if #trail <= 2 then
        local list_commands = {}
        for k,v in next, operations, nil do
            table.insert(list_commands, cmd .. " " .. k)
        end
        return list_commands
    end
end, "Downloads stuff into your data folder from an GitHub repo. Run 'grabber help' for a list of commands.")


-- Extra: Make sure the user retains their old repositories on a reload, and throw in a load from the disk for good measure.
if isReloading then
    grabber.Repositories = oldRepositories
    grabber.LoadRepositoriesFromDisk()
end
