require 'condo/engine'
require 'condo/errors'
require 'condo/configuration'


#Dir[File.join('condo', 'strata', '*.rb')].each do |file|	# Using autoload_paths now
#	require file[0..-4]	# Removes the .rb ext name
#end


module Condo
	
	#
	# TODO:: Simplify the parameters passed in
	#	Object options should be set at the application level
	#	The application can set these based on the custom params.
	#	Have an instance member that holds the parameter set: @upload
	#
	def self.included(base)
		base.class_eval do
			
			
			def new
				#
				# Returns the provider that will be used for this file upload
				#
				resident = current_resident
				
				@upload ||= {}
				@upload[:file_size] = params[:file_size].to_i
				@upload[:file_name] = (instance_eval &@@callbacks[:sanitize_filename])
				
				valid, errors = instance_eval &@@callbacks[:pre_validation]		# Ensure the upload request is valid before uploading
				
				if !!valid
					set_residence(nil, {:resident => resident, :params => @upload}) if condo_config.dynamic_provider_present?(@@namespace)
					residence = current_residence
					
					render :json => {:residence => residence.name}
					
				elsif errors.is_a? Hash
					render :json => errors, :status => :not_acceptable
				else
					render :nothing => true, :status => :not_acceptable
				end
			end
			
			def create
				#
				# Check for existing upload or create a new one
				# => mutually exclusive so can send back either the parts signature from show or a bucket creation signature and the upload_id
				#
				resident = current_resident
				
				@upload = {}
				@upload[:file_size] = params[:file_size].to_i
				@upload[:file_id] = params[:file_id]
				@upload[:file_name] = (instance_eval &@@callbacks[:sanitize_filename])
				@upload[:parameters] = (params[:parameters] || {}).merge((@upload[:parameters] || {}))	# Appliction takes priority
				
				upload = condo_backend.check_exists({
					:user_id => resident,
					:file_name => @upload[:file_name],
					:file_size => @upload[:file_size],
					:file_id => @upload[:file_id]
				})
				
				if upload.present?
					residence = set_residence(upload.provider_name, {
						:provider_location => upload.provider_location,
						:upload => upload
					})
					
					#
					# Return the parts or direct upload sig
					#
					request = nil
					if upload.resumable_id.present? && upload.resumable
						upload.object_options[:parameters] =  ({} || @upload[:parameters]).merge(upload.object_options[:paramters]) if @upload[:object_options].present? && @upload[:object_options][:parameters].present?	# This seems more secure (May need to request the next set of parts)
						request = residence.get_parts({
							:bucket_name => upload.bucket_name,
							:object_key => upload.object_key,
							:object_options => upload.object_options,
							:resumable_id => upload.resumable_id
						})
					else
						request = residence.new_upload({
							:bucket_name => upload.bucket_name,
							:object_key => upload.object_key,
							:object_options => upload.object_options,
							:file_size => upload.file_size,
							:file_id => upload.file_id
						})
					end
					
					render :json => request.merge(:upload_id => upload.id, :residence => residence.name)
				else
					#
					# Create a new upload
					#
					valid, errors = instance_eval &@@callbacks[:pre_validation]		# Ensure the upload request is valid before uploading
					
					
					if !!valid
						set_residence(nil, {:resident => resident, :params => @upload}) if condo_config.dynamic_provider_present?(@@namespace)
						residence = current_residence
						
						#
						# Build the request
						#
						request = residence.new_upload(@upload.merge!({
							:bucket_name => (instance_eval &@@callbacks[:bucket_name]),		# Allow the application to define a custom bucket name
							:object_key => (instance_eval &@@callbacks[:object_key]),			# The object key should also be generated by the application
							:object_options => (instance_eval &@@callbacks[:object_options])	# Do we want to mess with any of the options?
						}))
						resumable = request[:type] == :chunked_upload
						
						#
						# Save a reference to this upload in the database
						# => This should throw an error on failure
						#
						upload = condo_backend.add_entry(@upload.merge!({:user_id => resident, :provider_name => residence.name, :provider_location => residence.location, :resumable => resumable}))
						render :json => request.merge!(:upload_id => upload.id, :residence => residence.name)
						
					elsif errors.is_a? Hash
						render :json => errors, :status => :not_acceptable
					else
						render :nothing => true, :status => :not_acceptable
					end
				end
			end
			
			
			#
			# Authorisation check all of these
			#
			def edit
				#
				# Get the signature for parts + final commit
				#
				upload = current_upload
				
				if upload.resumable_id.present? && upload.resumable
					residence = set_residence(upload.provider_name, {:location => upload.provider_location, :upload => upload})
					
					request = residence.set_part({
						:bucket_name => upload.bucket_name,
						:object_key => upload.object_key,
						:object_options => upload.object_options,
						:resumable_id => upload.resumable_id,
						:part => params[:part],						# part may be called 'finish' for commit signature
						:file_id => params[:file_id]
					})
					
					render :json => request.merge!(:upload_id => upload.id)
				else
					render :nothing => true, :status => :not_acceptable
				end
			end
			
			
			def update
				#
				# Provide the upload id after creating a resumable upload (may not be completed)
				# => We then provide the first part signature
				#
				# OR
				#
				# Complete an upload
				#
				if params[:resumable_id]
					upload = current_upload
					if upload.resumable
						@current_upload = upload.update_entry :resumable_id => params[:resumable_id]
						edit
					else
						render :nothing => true, :status => :not_acceptable
					end
				else
					response = instance_exec current_upload, &@@callbacks[:upload_complete]
					if !!response
						current_upload.remove_entry
						render :nothing => true
					else
						render :nothing => true, :status => :not_acceptable
					end
				end
			end
			
			
			def destroy
				#
				# Delete the file from the cloud system - the client is not responsible for this
				#
				response = instance_exec current_upload, &@@callbacks[:destroy_upload]
				if !!response
					current_upload.remove_entry
					render :nothing => true
				else
					render :nothing => true, :status => :not_acceptable
				end
			end
			
			
			protected
			
			
			#
			# A before filter can be used to select the cloud provider for the current user
			# 	Otherwise the dynamic residence can be used when users are define their own storage locations
			#
			def set_residence(name, options = {})
				options[:namespace] = @@namespace
				@current_residence = condo_config.set_residence(name, options)
			end
			
			def current_residence
				@current_residence ||= condo_config.residencies[0]
			end
			
			def current_upload
				@current_upload ||= condo_backend.check_exists({:user_id => current_resident, :upload_id => (params[:upload_id] || params[:id])}).tap do |object|	#current_residence.name && current_residence.location && resident.id.exists?
					raise Condo::Errors::NotYourPlace unless object.present?
				end
			end
			
			def current_resident
				@current_resident ||= (instance_eval &@@callbacks[:resident_id]).tap do |object|	# instance_exec for params
					raise Condo::Errors::LostTheKeys unless object.present?
				end
			end
			
			def condo_backend
				Condo::Store
			end
			
			def condo_config
				Condo::Configuration.instance
			end
			
		
			#
			# Defines the default callbacks
			#
			(@@callbacks ||= {}).merge! Condo::Configuration.callbacks
			@@namespace ||= :global
			
			
			def self.set_callback(name, callback = nil, &block)
				if callback.is_a?(Proc)
					@@callbacks[name.to_sym] = callback
				elsif block.present?
					@@callbacks[name.to_sym] = block
				else
					raise ArgumentError, 'Condo callbacks must be defined with a Proc or Proc (lamba) object present'
				end
			end
			
			
			def self.set_namespace(name)
				@@namespace = name.to_sym
			end
		
		end
	end
	

end
