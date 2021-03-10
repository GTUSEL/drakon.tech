-- Autogenerated with DRAKON Editor 1.33
local table = table
local string = string
local pairs = pairs
local ipairs = ipairs
local type = type
local print = print
local os = os
local tostring = tostring

local global_cfg = global_cfg

local clock = require("clock")
local log = require("log")
local digest = require("digest")
local fiber = require("fiber")

local utf8 = require("lua-utf8")

local utils = require("utils")
local ej = require("ej")
local mail = require("mail")
local trans = require("trans")

local min_user_id = 2
local max_user_id = 30
local min_email = 3
local max_email = 254
local max_pass = 100
local min_pass = 6

local db = require(global_cfg.db)

setfenv(1, {}) 

function calc_expiry()
    local now = clock.time()
    local timeout = global_cfg.session_timeout
    local expires = now + timeout
    return expires
end

function change_password(id_email, old_password, password)
    local user = find_user(id_email)
    if (user) and (old_password) then
        if password then
            if #password < min_pass then
                return "ERR_PASSWORD_TOO_SHORT"
            else
                if #password > max_pass then
                    return "ERR_PASSWORD_TOO_LONG"
                else
                    local user_id = user[1]
                    local msg = check_password(
                    	user,
                    	old_password
                    )
                    if msg then
                        log_user_event(
                        	user_id,
                        	"change_password failed",
                        	{msg = msg}
                        )
                        return msg
                    else
                        set_password_kernel(user_id, password)
                        log_user_event(
                        	user_id,
                        	"change_password",
                        	{}
                        )
                        return nil
                    end
                end
            end
        else
            return "ERR_PASSWORD_EMPTY"
        end
    else
        return "ERR_WRONG_PASSWORD"
    end
end

function check_logoff(session_id)
    local session = db.session_get(session_id)
    if session then
        local sdata = session[3]
        local now = clock.time()
        if now > sdata.expires then
            delete_session(session, "timeout")
        end
    end
end

function check_password(user, password)
    local user_id = user[1]
    local udata = user[3]
    local now = clock.time()
    local message = nil
    if udata.enabled then
        local cdata = db.cred_get(user_id)
        if cdata then
            local valid_from = cdata.valid_from
            if (valid_from) and (now < valid_from) then
                message = "ERR_ACCOUNT_TEMP_DISABLED"
                cdata.valid_from = 
                 now + global_cfg.password_timeout
                db.cred_upsert(user_id, cdata)
                return message
            else
                local all = cdata.salt .. password
                local actual_hash = digest.sha512(all)
                if actual_hash == cdata.hash then
                    return nil
                else
                    message = "ERR_WRONG_PASSWORD"
                    cdata.valid_from = 
                     now + global_cfg.password_timeout
                    db.cred_upsert(user_id, cdata)
                    return message
                end
            end
        else
            return "ERR_WRONG_PASSWORD"
        end
    else
        return "ERR_ACCOUNT_DISABLED"
    end
end

function close_session(session)
    delete_session(session, "logout")
end

function create_session(ip, referer, path, report)
    local sdata = {
    	roles = default_roles(),
    	debug = false,
    	ip = ip,
    	user_id = "",
    	referer = referer,
    	path = path
    }
    return create_session_core(
    	"",
    	sdata,
    	report
    )
end

function create_session_core(user_id, sdata, report)
    local session_id = utils.random_string()
    local expires = calc_expiry()
    sdata.expires = expires
    sdata.created = os.time()
    db.session_insert(session_id, user_id, sdata)
    if report then
        ej.info(
        	"create_session",
        	{
        		ip = ip,
        		session_id = session_id,
        		referer = referer,
        		path = path		
        	}
        )
    end
    return session_id
end

function create_user(name, email, password, session_id, reg, ip)
    local result = nil
    if name then
        if type(name) == "string" then
            if #name < min_user_id then
                result = "ERR_USER_NAME_TOO_SHORT"
            else
                if #name > max_user_id then
                    result = "ERR_USER_NAME_TOO_LONG"
                else
                    if email then
                        if type(email) == "string" then
                            if #email < min_email then
                                result = "ERR_EMAIL_TOO_SHORT"
                            else
                                if #email > max_email then
                                    result = "ERR_EMAIL_TOO_LONG"
                                else
                                    local id = name:lower()
                                    if utils.good_id_symbols(id) then
                                        local ref = nil
                                        local path = nil
                                        if session_id then
                                            local session = db.session_get(session_id)
                                            if session then
                                                ref = session[3].referer
                                                path = session[3].path
                                            end
                                        end
                                        if #password < min_pass then
                                            return "ERR_PASSWORD_TOO_SHORT"
                                        else
                                            if #password > max_pass then
                                                return "ERR_PASSWORD_TOO_LONG"
                                            else
                                                local by_id = db.user_get(id)
                                                if by_id then
                                                    result = "ERR_USER_ID_NOT_UNIQUE"
                                                else
                                                    local space = db.space_get(id)
                                                    if space then
                                                        result = "ERR_USER_ID_NOT_UNIQUE"
                                                    else
                                                        email = email:lower()
                                                        local by_email = db.user_get_by_email(email)
                                                        if by_email then
                                                            result = "ERR_USER_EMAIL_NOT_UNIQUE"
                                                        else
                                                            local now = clock.time()
                                                            local data = {
                                                            	name = name,
                                                            	when_created = now,
                                                            	when_updated = now,
                                                            	enabled = true,
                                                            	admin = false,
                                                            	system = false,
                                                            	reg = reg,
                                                            	ref = ref,
                                                            	path = path,
                                                            	ip = ip
                                                            }
                                                            db.user_insert(id, email, data)
                                                            set_password_kernel(id, password)
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    else
                                        result = "ERR_USER_NAME_BAD_SYMBOLS"
                                    end
                                end
                            end
                        else
                            result = "ERR_USER_NAME_NOT_STRING"
                        end
                    else
                        result = "ERR_EMAIL_EMPTY"
                    end
                end
            end
        else
            result = "ERR_USER_NAME_NOT_STRING"
        end
    else
        result = "ERR_USER_NAME_EMPTY"
    end
    return result
end

function create_user_with_pass(user_id, email, udata, password)
    
end

function default_roles()
    return {
    	admin = false,
    	system = false
    }
end

function delete_session(session, reason)
    local session_id = session[1]
    local user_id = session[2]
    db.session_delete(session_id)
    log_user_event(
    	user_id,
    	"delete_session",
    	{
    		reason = reason,
    		session_id = session_id
    	}
    )
end

function delete_user(user_id)
    db.cred_delete(user_id)
    db.user_delete(user_id)
    log_user_event(user_id, "delete_user", {})
end

function find_user(id_email)
    if id_email then
        id_email = id_email:lower()
        local by_id = db.user_get(id_email)
        if by_id then
            return by_id
        else
            return db.user_get_by_email(id_email)
        end
    else
        return nil
    end
end

function find_users(data)
    local crit = utf8.lower(data.text)
    crit = utils.trim(crit)
    local found = {}
    local users = db.user_get_all()
    for _, user in ipairs(users) do
        local user_id = user[1]
        local udata = user[3]
        local name = udata.name
        if user_id:match(crit) then
            table.insert(
            	found,
            	name
            )
        end
    end
    return {
    	found = found
    }
end

function force_logout(user_id, time)
    local count = 0
    local user_sessions = db.session_get_by_user(user_id)
    for _, session in ipairs(user_sessions) do
        local session_id = session[1]
        local user_id = session[2]
        local sdata = session[3]
        if (sdata.created) and (not (sdata.created < time)) then
            
        else
            db.session_delete(session_id)
            count = count + 1
        end
    end
    return count
end

function force_logout_all_users(time)
    local count = 0
    local users = db.user_get_all()
    for _, user in ipairs(users) do
        local user_id = row[1]
        count = count + force_logout(user_id, time)
    end
    return count
end

function get_config()
    return {
    	SESSION_TIMEOUT = 60 * 4
    }
end

function get_create_session(session_id, ip, referer, path, report)
    local result = { 
    	roles = default_roles(),
    	user_id = "",
    	name = "",
    	debug = false
    }
    if session_id then
        local session = db.session_get(session_id)
        if session then
            local sdata = session[3]
            local expires = sdata.expires
            if clock.time() > expires then
                db.session_delete(
                	session_id
                )
                report = false
                session_id = create_session(
                	ip,
                	referer,
                	path,
                	report
                )
            else
                result.user_id = session[2]
                result.roles = sdata.roles or default_roles()
                result.name = sdata.name
                result.debug = not not sdata.debug
            end
        else
            session_id = create_session(
            	ip,
            	referer,
            	path,
            	report
            )
        end
    else
        session_id = create_session(
        	ip,
        	referer,
        	path,
        	report
        )
    end
    result.session_id = session_id
    return result
end

function get_or_create_usecret(user_id)
    return nil
end

function get_unsubscribe_code(user_id)
    return nil
end

function get_user(user_id)
    if user_id then
        local user = db.user_get(user_id)
        if user then
            local email = user[2]
            local udata = user[3]
            local result = {
            	user_id = user_id,
            	email = email,
            	block_email = udata.block_email,
            	name = udata.name,
            	admin = udata.admin,
            	system = udata.system,
            	enabled = udata.enabled,
            	debug = udata.debug,
            	max_spaces = udata.max_spaces,
            	license = udata.license,
            	had_trial = udata.had_trial or false
            }
            return result
        else
            return nil
        end
    else
        return nil
    end
end

function get_user_data(user_id)
    if user_id then
        local user = db.user_get(user_id)
        if user then
            local udata = user[3]
            return udata
        else
            return nil
        end
    else
        return nil
    end
end

function get_user_roles(user_id)
    if user_id then
        local user = db.user_get(user_id)
        if user then
            local udata = user[3]
            return {
            	admin = udata.admin,
            	system = udata.system
            }
        else
            return nil
        end
    else
        return nil
    end
end

function hello(value)
    return value * 5
end

function log_user_event(user_id, type, data)
    data.user_id = user_id
    ej.info(type, data)
end

function logon(session_id, id_email, password)
    if session_id then
        local session = db.session_get(session_id)
        if session then
            local user = find_user(id_email)
            if user then
                local msg = check_password(
                	user,
                	password
                )
                if msg then
                    ej.info(
                    	"logon failed",
                    	{
                    		session_id = session_id,
                    		msg = msg,
                    		id_email = id_email
                    	}
                    )
                    return false, msg
                else
                    local sdata = session[3]
                    local user_id = user[1]
                    local email = user[2]
                    local udata = user[3]
                    local new_session = reset_session(
                    	session_id,
                    	sdata,
                    	user_id,
                    	email,
                    	udata
                    )
                    log_user_event(
                    	user_id,
                    	"logon",
                    	{session_id = session_id}
                    )
                    return true, udata.name, user_id, email,
                    	new_session, udata
                end
            else
                ej.info(
                	"logon - wrong password",
                	{
                		session_id = session_id,
                		id_email = id_email
                	}
                )
                return false, "ERR_WRONG_PASSWORD"
            end
        else
            ej.info(
            	"logon - wrong password",
            	{
            		session_id = session_id,
            		id_email = id_email
            	}
            )
            return false, "ERR_WRONG_PASSWORD"
        end
    else
        ej.info(
        	"logon - wrong password",
        	{
        		session_id = session_id,
        		id_email = id_email
        	}
        )
        return false, "ERR_WRONG_PASSWORD"
    end
end

function logout(session_id)
    if session_id then
        local this_session = db.session_get(session_id)
        if this_session then
            local user_id = this_session[2]
            if user_id == "" then
                close_session(this_session)
            else
                logout_all(user_id)
            end
        end
    end
end

function logout_all(user_id)
    local user_sessions = db.session_get_by_user(user_id)
    for _, session in ipairs(user_sessions) do
        close_session(session)
    end
end

function make_cred(password)
    local salt = digest.urandom(64)
    local all = salt .. password
    local hash = digest.sha512(all)
    return {
    	salt = salt,
    	hash = hash
    }
end

function refresh_session(session)
    local session_id
    local user_id
    local sdata
    session_id, user_id, sdata = session:unpack()
    sdata.expires = calc_expiry()
    db.session_update(session_id, user_id, sdata)
end

function reset_password(id_email, session_id, language)
    local user = find_user(id_email)
    if user then
        local password = utils.random_string()
        password = password:sub(1, 8)
        local id = user[1]
        local email = user[2]
        set_password_kernel(id, password)
        log_user_event(
        	id,
        	"reset_password",
        	{session_id=session_id}
        )
        send_pass_reset_email(
        	id,
        	email,
        	password,
        	language
        )
        return true, {}
    else
        ej.info(
        	"reset_password fail",
        	{id_email = id_email, session_id=session_id}
        )
        return false, "ERR_USER_NOT_FOUND"
    end
end

function reset_session(old_session_id, sdata, user_id, email, udata)
    db.session_delete(
    	old_session_id
    )
    local roles = {
    	admin = not not udata.admin,
    	system = not not udata.system
    }
    sdata.email = email
    sdata.user_id = user_id
    sdata.roles = roles
    sdata.name = udata.name
    sdata.expires = calc_expiry()
    return create_session_core(
    	user_id,
    	sdata,
    	false
    )
end

function send_pass_reset_email(user_id, email, password, language)
    local htmlRaw = mail.get_template(
    	language,
    	"reset.html"
    )
    local textRaw = mail.get_template(
    	language,
    	"reset.txt"
    )
    local html = htmlRaw:gsub("USER_PASSWORD", password)
    html = html:gsub("USER_NAME", user_id)
    local text = textRaw:gsub("USER_PASSWORD", password)
    text = text:gsub("USER_NAME", user_id)
    local subject = trans.translate(
    	language,
    	"index",
    	"MES_RESET_DONE"
    )
    mail.send_mail(
    	user_id,
    	email,
    	subject,
    	text,
    	html,
    	nil
    )
end

function set_debug(user_id, debug)
    set_user_prop(
    	user_id,
    	"debug",
    	debug
    )
end

function set_password(admin_id, id_email, password)
    local user = find_user(id_email)
    if user then
        if password then
            local id = user[1]
            set_password_kernel(id, password)
            log_user_event(
            	admin_id,
            	"set_password",
            	{principal = id}
            )
            return nil
        else
            return "ERR_PASSWORD_EMPTY"
        end
    else
        return "ERR_USER_NOT_FOUND"
    end
end

function set_password_kernel(user_id, password)
    local cred = make_cred(password)
    db.cred_upsert(user_id, cred)
end

function set_session_ref(session_id, ref)
    local session = db.session_get(session_id)
    if session then
        local session_id
        local user_id
        local sdata
        session_id, user_id, sdata = session:unpack()
        sdata.referer = ref
        db.session_update(session_id, user_id, sdata)
    end
end

function set_user_prop(user_id, name, value)
    local user = db.user_get(user_id)
    if user then
        local email = user[2]
        local udata = user[3]
        udata[name] = value
        db.user_update(
        	user_id,
        	email,
        	udata
        )
    end
end

function unsubscribe(data)
    
end

function update_user(user_id, data)
    if user_id then
        local user = db.user_get(user_id)
        if user then
            local email = data.email
            if (email) and (not (#email < min_email)) then
                if #email > max_email then
                    return "ERR_EMAIL_TOO_LONG"
                else
                    email = email:lower()
                    local by_email = db.user_get_by_email(email)
                    if (by_email) and (not (by_email[1] == user_id)) then
                        return "ERR_USER_EMAIL_NOT_UNIQUE"
                    else
                        local udata = user[3]
                        udata.when_updated = clock.time()
                        udata.block_email = data.block_email
                        db.user_update(
                        	user_id,
                        	email,
                        	udata
                        )
                        log_user_event(
                        	user_id,
                        	"update_user",
                        	{}
                        )
                        return nil
                    end
                end
            else
                return "ERR_EMAIL_TOO_SHORT"
            end
        else
            return "ERR_USER_NOT_FOUND"
        end
    else
        return "ERR_USER_NOT_FOUND"
    end
end


return {
	hello = hello,
	create_user = create_user,
	set_password = set_password,
	change_password = change_password,
	logon = logon,
	logout = logout,
	get_create_session = get_create_session,
	get_user = get_user,
	update_user = update_user,
	find_users = find_users,
	set_debug = set_debug,
	set_user_prop = set_user_prop,
	reset_password = reset_password,
	unsubscribe = unsubscribe,
	get_unsubscribe_code = get_unsubscribe_code,
	delete_user = delete_user,
	logout_all = logout_all,
	find_user = find_user,
	set_session_ref = set_session_ref,
	check_logoff = check_logoff,
	force_logout_all_users = force_logout_all_users,
	get_user_roles = get_user_roles
}
