require 'localizing_model'

class Script < ActiveRecord::Base
	include LocalizingModel

	belongs_to :user

	has_many :script_versions, dependent: :destroy
	has_many :script_applies_tos, -> {order(:text)}, dependent: :destroy, autosave: true
	has_many :discussions, -> { readonly.order('COALESCE(DateLastComment, DateInserted)').where('Closed = 0') }, :class_name => 'ForumDiscussion', :foreign_key => 'ScriptID'
	has_many :cpd_duplication_scripts, dependent: :destroy
	has_many :cpd_duplications, :through => :cpd_duplication_scripts
	has_many :script_set_script_inclusions, foreign_key: 'child_id', dependent: :destroy
	has_many :favorited_in_sets, -> {includes(:user).where('favorite = true')}, :through => :script_set_script_inclusions, :class_name => 'ScriptSet', :source => 'parent'
	has_many :favoriters, :through => :favorited_in_sets, :class_name => 'User', :source => 'user'
	has_many :localized_attributes, class_name: 'LocalizedScriptAttribute', autosave: true, dependent: :destroy
	has_many :localized_names, -> {where(:attribute_key => 'name')}, :class_name => 'LocalizedScriptAttribute'
	has_many :localized_descriptions, -> {where(:attribute_key => 'description')}, :class_name => 'LocalizedScriptAttribute'
	has_many :localized_additional_infos, -> {where(:attribute_key => 'additional_info')}, :class_name => 'LocalizedScriptAttribute'
	has_many :compatibilities, autosave: true, dependent: :destroy

	has_one :syntax_highlighted_code, dependent: :destroy

	belongs_to :script_type
	belongs_to :script_sync_source
	belongs_to :script_sync_type
	belongs_to :script_delete_type
	belongs_to :license
	belongs_to :locale
	belongs_to :replaced_by_script, :class_name => 'Script'

	attr_accessor :adult_content_self_report, :not_adult_content_self_report

	scope :not_deleted, -> {where('script_delete_type_id is null')}
	scope :active, ->(script_subset) {
		f = not_deleted
		case script_subset
			when :greasyfork
				f = f.where(sensitive: false)
			when :sleazyfork
				f = f.where(sensitive: true)
			when :all
			else
				raise ArgumentError.new("Invalid argument #{script_subset}")
		end
		f
	}
	scope :listable, ->(script_subset) {active(script_subset).where(:script_type_id => 1)}
	scope :libraries, ->(script_subset) {active(script_subset).where(:script_type_id => 3)}
	scope :reported, -> {not_deleted.joins(:discussions).includes(:user).uniq.where('GDN_Discussion.Rating = 1').where('Closed = 0')}
	scope :reported_not_adult, -> {not_deleted.includes(:user).where('not_adult_content_self_report_date IS NOT NULL')}
	scope :requested_permanent_deletion, -> {where('permanent_deletion_request_date is not null')}
	scope :for_all_sites, -> {includes(:script_applies_tos).references(:script_applies_tos).where('script_applies_tos.id IS NULL')}
	scope :redistributable, ->(script_subset) {listable(script_subset).includes(:user).references([:scripts, :users]).where('scripts.approve_redistribution OR (scripts.approve_redistribution IS NULL AND users.approve_redistribution)')}

	# Must have a default name and description
	validates_presence_of :default_name, :message => :script_missing_name, :unless => Proc.new {|s| s.library?}
	validates_presence_of :name, :if => Proc.new {|s| s.library?}
	validates_presence_of :description, :message => :script_missing_description, :unless => Proc.new {|r| r.deleted? || r.library?}
	validates_presence_of :description, :unless => Proc.new {|r| r.deleted? || !r.library?}

	MAX_LENGTHS = {:name => 100, :description => 500, :additional_info => 50000}
	validates_each *MAX_LENGTHS.keys do |script, attr, nothing|
		len = MAX_LENGTHS[attr]
		script.localized_attributes_for(attr)
			.select{|la| !la.attribute_value.nil?}
			.select{|la| la.attribute_value.length > len}
			.each{|la|
				# use @meta if this came from a meta
				if [:name, :description].include?(attr) and !script.library?
					validation_key = la.localized_meta_key
				else
					validation_key = attr
				end
				script.errors[validation_key] << I18n.t('errors.messages.too_long', {:count => len})}
	end

	# Every locale that provides a name must have a description that's different than the name
	validate do |script|
		localized_names = script.localized_attributes_for('name')
		localized_descriptions = script.localized_attributes_for('description')
		localized_names.each {|ln|
			matching_description = localized_descriptions.select{|ld| ld.locale == ln.locale}.first
			validation_key = script.library? ? :description : LocalizedScriptAttribute.localized_meta_key(:description, ln.locale, false)
			if matching_description.nil?
				script.errors.add(validation_key, I18n.t('errors.messages.blank'))
			elsif matching_description.attribute_value == ln.attribute_value
				script.errors.add(validation_key, I18n.t('errors.messages.script_name_same_as_description'))
			end
		}
	end

	validates_each :localized_attributes do |s, attr, children|
		s.errors[attr].clear
		children.each do |child|
			child.errors.keys.each{|key| s.errors[attr.to_s + '.' + key.to_s].clear}
			next if child.marked_for_destruction? or child.valid?
			child.errors.each do |child_attr, msg|
				s.errors[:base] << I18n.t("activerecord.attributes.script." + child.attribute_key) + " - " + I18n.t("activerecord.attributes.script." + child_attr.to_s, :default => child_attr.to_s) + " " + msg
			end
		end
	end

	validates_presence_of :user_id, :code_updated_at, :script_type

	validates_format_of :sync_identifier, :with => URI::regexp(%w(http https)), :message => :script_sync_identifier_bad_protocol, :if => Proc.new {|r| r.script_sync_source_id == 1}

	strip_attributes :only => [:sync_identifier]

	before_validation :set_locale
	def set_locale
		return if !locale.nil?
		self.locale = detect_locale 
		localized_attributes.select{|la| la.locale.nil?}.each{|la| la.locale = self.locale}
		true
	end

	before_validation :set_default_name
	def set_default_name
		self.default_name = default_localized_value_for('name')
		true
	end

	before_validation :set_sensitive_flag
	def set_sensitive_flag
		self.sensitive ||= (adult_content_self_report || for_sensitive_site?)
		true
	end

	def matching_sensitive_sites
		SensitiveSite.where(domain: script_applies_tos.select(&:domain).map(&:text))
	end

	def for_sensitive_site?
		return matching_sensitive_sites.any?
	end

	after_save :update_syntax_highlighted_code
	def update_syntax_highlighted_code
		html = SyntaxHighlightedCode.highlight(get_newest_saved_script_version.rewritten_code)
		if html.nil?
			syntax_highlighted_code.delete if !syntax_highlighted_code.nil?
		else
			build_syntax_highlighted_code if syntax_highlighted_code.nil?
			syntax_highlighted_code.html = html
			syntax_highlighted_code.save
		end
	end

	before_destroy do |script|
		["install_counts", "daily_install_counts", "update_check_counts", "daily_update_check_counts"].each do |table|
			script.class.connection.execute "DELETE FROM #{table} WHERE script_id = #{script.id}"
		end
	end

	def apply_from_script_version(script_version)
		# Copy additional_info from script versions. Retain syncing info.
		original_script_las = localized_attributes_for('additional_info').to_a
		# Try to retain the records - search by locale
		script_version.localized_attributes_for('additional_info').each{|la|
			matching_osla = original_script_las.find{|osla| osla.locale_id == la.locale_id}
			if matching_osla.nil?
				# New
				matching_osla = build_localized_attribute(la)
			else
				matching_osla.value_markup = la.value_markup
				matching_osla.attribute_value = la.attribute_value
				# We've found this one, don't search for it any more.
				original_script_las.delete(matching_osla)
			end
		}
		# Delete any that are gone
		original_script_las.each(&:mark_for_destruction)

		meta = ScriptVersion.parse_meta(script_version.rewritten_code)

		['name', 'description'].each{|key| update_localized_attribute(meta, key)}

		if script_version.truncate_description
			localized_attributes_for('description').select{|la| la.attribute_value.length > MAX_LENGTHS[:description]}.each{|la| la.attribute_value = la.attribute_value[0,MAX_LENGTHS[:description]]}
		end

		update_children(:script_applies_tos, script_version.calculate_applies_to_names)

		if new_record? or self.code_updated_at.nil?
			self.code_updated_at = Time.now
		else
			newest_sv = get_newest_saved_script_version
			self.code_updated_at = Time.now if newest_sv.nil? or newest_sv.code != script_version.code
		end

		self.license_text = meta.has_key?('license') ? meta['license'].first : nil
		if self.license_text.nil?
			self.license = nil
		else
			self.license = License.order('priority DESC, id').find do |l|
				self.license_text =~ Regexp.new(l.pattern)
			end
		end

		self.namespace = meta.has_key?('namespace') ? meta['namespace'].first : nil
		self.version = script_version.version

		self.contribution_url = !meta.has_key?('contributionURL') ? nil : meta['contributionURL'].find {|url|
			URI::regexp(%w(http https bitcoin)) =~ url
		}
		self.contribution_amount = (!self.contribution_url.nil? && meta.has_key?('contributionAmount')) ? meta['contributionAmount'].first : nil

		if meta.has_key?('supportURL')
			self.support_url = meta['supportURL'].find {|url|
				next false if url.size > 500
				# mailto is always OK
				next true if URI::regexp(%w(mailto)) =~ url
				# http(s) is also OK
				next false unless URI::regexp(%w(http https)) =~ url
				# avoid self-linking, there's UI on the same page for discussions
				begin
					next URI(url).host != 'greasyfork.org'
				rescue
					next false
				end
			}
		else
			self.support_url = nil
		end

		new_compatibility_data = []
		['compatible', 'incompatible'].each do |key|
			next if !meta.has_key?(key)
			compatible = key == 'compatible'
			meta[key].each do |line|
				browser_match = /\A([a-z]+).*/i.match(line)
				next if browser_match.nil?
				browser = Browser.where(code: browser_match[1].downcase).first
				next if browser.nil?
				comments_split = line.split(' ', 2)
				comments = comments_split.length == 2 ? comments_split[1] : nil
				new_compatibility_data << {compatible: compatible, browser: browser, comments: comments}
			end
		end
		update_children(:compatibilities, new_compatibility_data)
	end

	def get_newest_saved_script_version
		# get the most recently saved record
		script_versions.reverse.each do |sv|
			return sv if !sv.new_record?
		end
		return nil
	end

	def self.record_install(id, ip)
		Script.connection.execute("INSERT IGNORE INTO daily_install_counts (script_id, ip) VALUES (#{Script.connection.quote_string(id)}, '#{Script.connection.quote_string(ip)}');")
	end

	def self.record_update_check(id, ip)
		Script.connection.execute("INSERT IGNORE INTO daily_update_check_counts (script_id, ip) VALUES (#{Script.connection.quote_string(id)}, '#{Script.connection.quote_string(ip)}');")
	end

	def active?
		!deleted?
	end

	def library?
		script_type_id == 3
	end

	def listable?
		active? and script_type_id == 1
	end

	def unlisted?
		script_type_id == 2
	end

	def redistributable?
		approve_redistribution.nil? ? user.approve_redistribution == true : approve_redistribution
	end

	def name(lookup_locale = nil)
		return localized_value_for('name', lookup_locale)
	end

	def description(lookup_locale = nil)
		return localized_value_for('description', lookup_locale)
	end

	def additional_info(lookup_locale = nil)
		return localized_value_for('additional_info', lookup_locale)
	end

	def additional_info_markup(lookup_locale = nil)
		la = localized_attribute_for('additional_info', lookup_locale)
		return nil if la.nil?
		return la.value_markup
	end

	def slugify(name)
		# take out swears
		r = name.downcase.gsub(/motherfucking|motherfucker|fucking|fucker|fucks|fuck|shitty|shits|shit|niggers|nigger|cunts|cunt/, '')
		# multiple non-alphas into one
		r.gsub!(/([^[:alnum:]])[^[:alnum:]]+/) {|s| $1}
		# leading non-alphas
		r.gsub!(/^[^[:alnum:]]+/, '')
		# trailing non-alphas
		r.gsub!(/[^[:alnum:]]+$/, '')
		# non-alphas into dashes
		r.gsub!(/[^[:alnum:]]/, '-')
		# use "script" if we don't have something suitable
		r = 'script' if r.empty?
		return r
	end

	# Full name minus URL-y characters
	def url_name
		return name.gsub(/[\?\&\/\#\.]+/, '')
	end

	def to_param
		"#{id}-#{slugify(name)}"
	end

	def deleted?
		!script_delete_type.nil?
	end

	def detect_locale
		ft = full_text
		return if ft.nil?
		if Greasyfork::Application.config.enable_detect_locale
			begin
				dl_lang_code = DetectLanguage.simple_detect(ft)
			rescue Exception => ex
				Rails.logger.error "Could not detect language - #{ex}"
			end
			if !dl_lang_code.nil?
				locales = Locale.where(:detect_language_code => dl_lang_code)
				return locales.first if !locales.empty?
				Rails.logger.error "detect_language gave unrecognized code #{dl_lang_code}"
			end
		end
		# assume english
		english = Locale.where(:code => 'en').first
		raise "Me fail english? That's unpossible!" if english.nil?
		return english
	end

	def license_display
		if license.nil?
			return "<i>#{I18n.t('scripts.no_license')}</i>".html_safe if license_text.nil?
			return license_text
		end
		return license.html.html_safe
	end

	def code_url
		return url_helpers.script_library_js_url(self, :version => get_newest_saved_script_version.id, :name => url_name) if library?
		return url_helpers.script_user_js_url(self, :name => url_name)
	end

	def serializable_hash(options = nil)
		super({ only: [:id, :daily_installs, :total_installs, :fan_score, :good_ratings, :ok_ratings, :bad_ratings, :created_at, :code_updated_at, :namespace, :support_url, :contribution_url, :contribution_amount] }.merge(options || {})).merge({
			name: default_name,
			description: default_localized_value_for('description'),
			url: url_helpers.script_url(nil, self),
			code_url: code_url,
			license: license_text,
			version: version,
			locale: locale.nil? ? nil : locale.code,
			redistributable: redistributable?,
			deleted: deleted?
		})
	end

private

	def url_helpers
		Rails.application.routes.url_helpers
	end

	# all text content of non-localized attributes for this script (for language detection)
	def full_text
		parts = []
		parts << name if !name.nil? and !name.empty?
		parts << description if !description.nil? and !description.empty?
		la = localized_attributes.select{|la| la.attribute_key == 'additional_info' && la.attribute_default}.first
		if !la.nil?
			additional_text = ApplicationController.helpers.format_user_text_as_plain(la.attribute_value, la.value_markup)
			parts << additional_text if !additional_text.nil? and !additional_text.empty?
		end
		return nil if parts.empty?
		return parts.join("\n")
	end

	def update_localized_attribute(meta_keys, attr_name)
		default_value = meta_keys.has_key?(attr_name) ? meta_keys[attr_name].first : nil
		# for libraries, if there's no default, just leave as is
		return if library? && default_value.nil?

		existing_localized_attributes = localized_attributes_for(attr_name)

		if !default_value.nil?
			default_la = existing_localized_attributes.find{|la| la.locale == locale && la.attribute_key == attr_name && la.attribute_default}
			if default_la.nil?
				default_la = localized_attributes.build({attribute_key: attr_name, attribute_default: true, locale: locale})
			else
				existing_localized_attributes.delete(default_la)
			end
			default_la.assign_attributes({attribute_value: default_value, value_markup: 'text'})
		end

		meta_keys.select{|n, v| n.starts_with?(attr_name + ':')}.each{ |n, v|
			locale_code = n.split(':', 2).last
			meta_locale = Locale.where(:code => locale_code).first
			if meta_locale.nil?
				Rails.logger.error "Unknown locale code - #{locale_code}"
				next
			end
			matching_la = existing_localized_attributes.find{|la| la.locale == meta_locale && la.attribute_key == attr_name}
			if matching_la.nil?
				matching_la = localized_attributes.build({attribute_key: attr_name, locale: meta_locale})
			else
				existing_localized_attributes.delete(matching_la)
			end
			matching_la.assign_attributes({attribute_value: v.first, attribute_default: false, value_markup: 'text'})
		}

		existing_localized_attributes.each(&:mark_for_destruction)
	end

	def update_children(child_name, new_data)
		existing_children = send(child_name).to_a
		new_data.each {|new_hash|
			# See if a record like that already exists.
			matching_existing = existing_children.find{|child|
				new_hash.keys.all?{|k| new_hash[k] == child.send(k)}
			}
			# Leave it alone, remove it from the search array, and move on
			if !matching_existing.nil?
				existing_children.delete(matching_existing)
				next
			end
			# Make a new one
			send(child_name).build(new_hash)
		}
		# Anything left in the search array, mark for destruction
		existing_children.each(&:mark_for_destruction)
	end

	def self.subsets
		[:greasyfork, :sleazyfork, :all]
	end
end
