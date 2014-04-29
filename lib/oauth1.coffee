# OAuth daemon
# Copyright (C) 2013 Webshell SAS
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

request = require 'request'
check = require './check'
db = require './db'

OAuth1ResponseParser = require './oauth1-response-parser'
OAuthBase = require './oauth-base'

class OAuth1 extends OAuthBase
	constructor: (provider, parameters) ->
		super 'oauth1', provider, parameters

	authorize: (opts, callback) ->
		@_createState opts, (err, state) =>
			return callback err if err
			@_getRequestToken state.id, opts, (err, response, body) =>
				return callback err if err
				@_parseGetRequestTokenResponse response, body, opts, state.id, (err, parsedResponse) =>
					return callback err if err
					@_saveRequestTokenSecret state.id, parsedResponse.oauth_token_secret, opts, (err) =>
						return callback err if err
						authorizeUrl = @_buildAuthorizeUrl opts, state.id, (query) ->
							query.oauth_token = parsedResponse.oauth_token
						callback null, authorizeUrl

	_getRequestToken: (stateId, opts, callback) ->
		configuration = @_oauthConfiguration.request_token
		placeholderValues = { state: stateId, callback: @_serverCallbackUrl }
		query = @_buildQuery(configuration.query, placeholderValues, opts.options?.request_token)
		headers = @_buildHeaders(configuration)
		options = @_buildRequestOptions(configuration, headers, query)
		options.oauth = {
			callback: query.oauth_callback
			consumer_key: @_parameters.client_id
			consumer_secret: @_parameters.client_secret
		}
		request options, (err, response, body) =>
			return callback err if err
			callback(null, response, body)

	_parseGetRequestTokenResponse: (response, body, opts, stateId, callback) ->
		acceptFormat = @_getAcceptFormat(@_oauthConfiguration.request_token)
		responseParser = new OAuth1ResponseParser(response, body, acceptFormat, 'request_token')
		responseParser.parse (err, parsedResponse) =>
			return callback err if err
			callback(null, parsedResponse)

	_saveRequestTokenSecret: (stateId, requestTokenSecret, opts, callback) ->
		db.states.setToken stateId, requestTokenSecret, (err, returnCode) ->
			return callback err if err
			callback(null)

	access_token: (state, req, response_type, callback) ->
		if not req.params.oauth_token && not req.params.error
			req.params.error_description ?= 'Authorization refused'

		# manage errors in callback
		if req.params.error || req.params.error_description
			err = new check.Error
			err.error req.params.error_description || 'Error while authorizing'
			err.body.error = req.params.error if req.params.error
			err.body.error_uri = req.params.error_uri if req.params.error_uri
			return callback err

		err = new check.Error
		if @_oauthConfiguration.authorize.ignore_verifier == true
			err.check req.params, oauth_token:'string'
		else
			err.check req.params, oauth_token:'string', oauth_verifier:'string'
		return callback err if err.failed()

		configuration = @_oauthConfiguration.access_token
		placeholderValues = { state: state.id, callback: @_serverCallbackUrl }
		@_setExtraRequestAuthorizeParameters(req, placeholderValues)
		query = @_buildQuery(configuration.query, placeholderValues)
		headers = @_buildHeaders(configuration)
		options = @_buildRequestOptions(configuration, headers, query)
		options.oauth = {
			callback: query.oauth_callback
			consumer_key: @_parameters.client_id
			consumer_secret: @_parameters.client_secret
			token: req.params.oauth_token
			token_secret: state.token
		}
		if @_oauthConfiguration.authorize.ignore_verifier != true
			options.oauth.verifier = req.params.oauth_verifier
		else
			options.oauth.verifier = ''
		delete query.oauth_callback

		# do request to access_token
		request options, (e, r, body) =>
			return callback(e) if e
			acceptFormat = @_getAcceptFormat(configuration)
			responseParser = new OAuth1ResponseParser(r, body, acceptFormat, 'access_token')
			responseParser.parse (err, parsedResponse) =>
				return callback err if err
				expire = @_getExpireParameter(parsedResponse)
				requestclone = @_cloneRequest()
				result =
					oauth_token: parsedResponse.oauth_token
					oauth_token_secret: parsedResponse.oauth_token_secret
					expires_in: expire
					request: requestclone
				@_setExtraResponseParameters(configuration, parsedResponse, result)
				@_setExtraRequestAuthorizeParameters(req, result)
				callback null, result

	request: (req, callback) ->
		if ! @_parameters.oauthio.oauth_token || ! @_parameters.oauthio.oauth_token_secret
			return callback new check.Error "You must provide 'oauth_token' and 'oauth_token_secret' in 'oauthio' http header"

		options = @_buildServerRequestOptions(req)
		options.oauth =
			consumer_key: @_parameters.client_id
			consumer_secret: @_parameters.client_secret
			token: @_parameters.oauthio.oauth_token
			token_secret: @_parameters.oauthio.oauth_token_secret

		# do request
		callback null, options

module.exports = OAuth1
