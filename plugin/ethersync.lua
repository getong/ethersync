local ignored_ticks = {}
local sep = "\t"

local ns_id = vim.api.nvim_create_namespace('Ethersync')
local virtual_cursor
local server = vim.loop.new_tcp()

function byteOffsetToCharOffset(byteOffset)
    local content = vim.fn.join(vim.api.nvim_buf_get_lines(0, 0, -1, true), "\n")
    return vim.fn.charidx(content, byteOffset, true)
end

function charOffsetToByteOffset(charOffset)
    local content = vim.fn.join(vim.api.nvim_buf_get_lines(0, 0, -1, true), "\n")
    if charOffset >= vim.fn.strchars(content) then
        return vim.fn.strlen(content)
    else
        return vim.fn.byteidxcomp(content, charOffset)
    end
end

function indexToRowCol(index)
    -- First, calculate which byte the (UTF-16) index corresponds to.
    print("index: " .. index)
    local byte = charOffsetToByteOffset(index)

    print("byte: " .. byte)

    -- Catch a special case: Querying the position after the last character.
    --local bufferLength = vim.fn.wordcount()["bytes"]
    --local afterLastChar = byte >= bufferLength
    --if afterLastChar then
    --    byte = bufferLength - 1
    --end

    local row = vim.fn.byte2line(byte + 1) - 1
    --print("row: " .. row)
    local col = byte - vim.api.nvim_buf_get_offset(0, row)

    return row, col
end

function rowColToIndex(row, col)
    local byte = vim.fn.line2byte(row + 1) + col - 1
    return byteOffsetToCharOffset(byte)
end

function ignoreNextUpdate()
    local nextTick = vim.api.nvim_buf_get_changedtick(0)
    ignored_ticks[nextTick] = true
end

function insert(index, content)
    local row, col = indexToRowCol(index)
    ignoreNextUpdate()
    vim.api.nvim_buf_set_text(0, row, col, row, col, vim.split(content, "\n"))
end

function delete(index, length)
    local row, col = indexToRowCol(index)
    local rowEnd, colEnd = indexToRowCol(index + length)
    ignoreNextUpdate()
    vim.api.nvim_buf_set_text(0, row, col, rowEnd, colEnd, { "" })
end

function setCursor(head, anchor)
    vim.schedule(function()
        if head == anchor then
            anchor = head + 1
        end

        if head > anchor then
            head, anchor = anchor, head
        end

        -- If the cursor is at the end of the buffer, don't show it.
        if head == vim.fn.strchars(vim.fn.join(vim.api.nvim_buf_get_lines(0, 0, -1, true), "\n")) then
            return
        end

        local row, col = indexToRowCol(head)
        local rowAnchor, colAnchor = indexToRowCol(anchor)

        vim.api.nvim_buf_set_extmark(0, ns_id, row, col, {
            id = virtual_cursor,
            hl_mode = 'combine',
            hl_group = 'TermCursor',
            end_col = colAnchor,
            end_row = rowAnchor
        })
    end)
end

function Ethersync()
    if vim.fn.isdirectory(vim.fn.expand('%:p:h') .. '/.ethersync') ~= 1 then
        print("Did not find .ethersync directory, quitting")
        return
    end

    print('Ethersync activated!')
    --vim.opt.modifiable = false

    local row = 0
    local col = 0
    virtual_cursor = vim.api.nvim_buf_set_extmark(0, ns_id, row, col, {
        hl_mode = 'combine',
        hl_group = 'TermCursor',
        end_col = col + 0
    })

    --setCursor(12,10)

    connect()

    vim.api.nvim_buf_attach(0, false, {
        on_bytes = function(the_string_bytes, buffer_handle, changedtick, start_row, start_column, byte_offset,
                            old_end_row, old_end_column, old_end_byte_length, new_end_row, new_end_column,
                            new_end_byte_length)
            -- Did the change come from us? If so, ignore it.
            if ignored_ticks[changedtick] then
                ignored_ticks[changedtick] = nil
                return
            end

            --print("start_row: " .. start_row)
            --print("num lines: " .. vim.fn.line('$'))
            --local num_rows = vim.fn.line('$')
            --if start_row == num_rows-1 and start_column == 0 and new_end_column == 0 then
            --    -- Edit is after the end of the buffer. Ignore it.
            --    return
            --end

            local new_content_lines = vim.api.nvim_buf_get_text(buffer_handle, start_row, start_column,
                start_row + new_end_row, start_column + new_end_column, {})
            local changed_string = table.concat(new_content_lines, "\n")

            local filename = vim.fs.basename(vim.api.nvim_buf_get_name(0))

            local charOffset = byteOffsetToCharOffset(byte_offset)

            if new_end_byte_length >= old_end_byte_length then
                server:write(vim.fn.join({ "insert", filename, charOffset, changed_string }, sep))
            else
                local length = old_end_byte_length - new_end_byte_length -- TODO: Convert this to character length.
                server:write(vim.fn.join({ "delete", filename, charOffset, length }, sep))
            end
        end
    })

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        callback = function()
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            local head = rowColToIndex(row - 1, col)

            if head == -1 then
                -- TODO what happens here?
                return
            end

            -- Is there a visual selection?
            local visualSelection = vim.fn.mode() == 'v' or vim.fn.mode() == 'V' or vim.fn.mode() == ''

            local anchor = head
            if visualSelection then
                local _, rowV, colV = unpack(vim.fn.getpos("v"))
                anchor = rowColToIndex(rowV - 1, colV)
                if head < anchor then
                else
                    head = head + 1
                    anchor = anchor - 1
                end
            end

            local filename = vim.fs.basename(vim.api.nvim_buf_get_name(0))

            server:write(vim.fn.join({ "cursor", filename, head, anchor }, sep))
        end })
end

function connect()
    server:connect("127.0.0.1", 9000, function(err)
        if err then
            print(err)
        end
    end)
    server:read_start(function(err, data)
        if err then
            print(err)
            return
        end
        if data then
            print(data)
            local parts = vim.split(data, sep)
            if parts[1] == "insert" then
                local filename = parts[2]
                local index = tonumber(parts[3])
                local content = parts[4]
                vim.schedule(function()
                    if filename == vim.fs.basename(vim.api.nvim_buf_get_name(0)) then
                        insert(index, content)
                    end
                end)
            elseif parts[1] == "delete" then
                local filename = parts[2]
                local index = tonumber(parts[3])
                local length = tonumber(parts[4])
                vim.schedule(function()
                    if filename == vim.fs.basename(vim.api.nvim_buf_get_name(0)) then
                        delete(index, length)
                    end
                end)
            elseif parts[1] == "cursor" then
                local filename = parts[2]
                local head = tonumber(parts[3])
                local anchor = tonumber(parts[4])
                --if filename == vim.fs.basename(vim.api.nvim_buf_get_name(0)) then
                setCursor(head, anchor)
                --end
            end
        end
    end)
end

-- When new buffer is loaded, run Ethersync.
vim.api.nvim_exec([[
augroup Ethersync
    autocmd!
    autocmd BufEnter * lua Ethersync()
augroup END
]], false)

vim.api.nvim_create_user_command('Ethersync', Ethersync, {})
vim.keymap.set('n', '<Leader>p', Ethersync)
