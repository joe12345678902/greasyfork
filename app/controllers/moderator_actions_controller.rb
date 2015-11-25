class ModeratorActionsController < ApplicationController

	def index
		@actions = ModeratorAction.includes([:script, :moderator, :user, :mass]).order('id desc').paginate(:page => params[:page], :per_page => 100)
		@canonical_params = [:page]
	end
end
