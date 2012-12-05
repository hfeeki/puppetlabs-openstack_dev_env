#
# class that hold utilities that I use to test openstack
#
module Puppetlabs
  module OsTester

    def cmd_system (cmd)
      result = system cmd
      raise(RuntimeError, $?) unless $?.success?
      result
    end

    def git_cmd(cmd)
      command = 'git ' + cmd
      Open3.popen3(*command) do |i, o, e, t|
        raise StandardError, e.read unless (t ? t.value : $?).success?
        o.read.split("\n")
      end
    end

    def on_box (box, cmd)
      cmd_system("vagrant ssh #{box} -c '#{cmd}'")
    end

    # destroy all vagrant instances
    def destroy_all_vms
      puts "About to destroy all vms..."
      cmd_system('vagrant destroy -f')
      puts "Destroyed all vms"
    end

    # adds the specified remote name as a read/write remote
    def dev_setup(remote_name)
      each_repo do |module_name|
        # need to handle more failure cases
        remotes = git_cmd('remote')
        if remotes.include?(remote_name)
          puts "Did not have to add remote #{remote_name} to #{module_name}"
        elsif ! remotes.include?('origin')
          raise(Exception, "Repo #{module_name} has no remote called origin, failing")
        else
          remote_url = git_cmd('remote show origin').detect {|x| x =~ /\s+Push\s+URL: / }
          if remote_url =~ /(git|https?):\/\/(.+)\/(.+)?\/(.+)/
            url = "git@#{$2}:#{remote_name}/#{$4}"
          else
            puts "remote_url #{remote_url} did not have the expected format. weird..."
          end
          puts "Adding remote #{remote_name} as #{url}"
          git_cmd("remote add #{remote_name} #{url}")
        end
      end
    end


    def pull_all
      each_repo do |module_name|
        puts "Pulling repo: #{module_name}"
        puts '  ' + git_cmd('pull').join("\n  ")
      end
    end


    def status_all
      each_repo do |module_name|
        status = git_cmd('status')
        if status.include?('nothing to commit (working directory clean)')
          puts "Module #{module_name} has not changed" if verbose
        else
          puts "Uncommitted changes for: #{module_name}"
          puts "  #{status.join("\n  ")}"
        end
      end
    end

    def check_tags(project_name=nil)
      each_repo do |module_name|
        require 'puppet'
        if ! project_name || project_name == module_name
          modulefile = File.join(Dir.getwd, 'Modulefile')
          if File.exists?(modulefile)
            print module_name
            metadata  = ::Puppet::ModuleTool::Metadata.new
            ::Puppet::ModuleTool::ModulefileReader.evaluate(metadata, modulefile)
            print ':' + metadata.version
            branch_output = git_cmd('branch')
            if branch_output.first =~ /\* (.+)/
              puts ":#{$1}"
              puts '  ' + git_cmd("log #{metadata.version}..HEAD --oneline").join("\n  ")
              puts ''
            else
              puts '  ' + branch_output.join("\n  ")
            end
          else
            puts "#{module_name} does not have a Modulefile"
          end
        end
      end
    end

    # given a pull request, return true if we should test it.
    # this means that is can be merged, and has a comment where one of the admin users

    def deploy_two_node
      cmd_system('vagrant up openstack_controller')
      cmd_system('vagrant up compute1')
    end

    def refresh_modules
      cmd_system('librarian-puppet clean')
      cmd_system('librarian-puppet install')
      FileUtils.rm(checkedout_file)
    end

    def each_repo(&block)
      require 'librarian/puppet'
      require 'librarian/puppet/source/git'
      # create a manifest
      # TODO replace this to use librarian puppet
      env = Librarian::Puppet::Environment.new()
      # this is the lock file, so it assumes that install has been run
      env.lock.manifests.each do |manifest|
        # I only care about git sources
        if manifest.source.is_a? Librarian::Puppet::Source::Git
          module_name = manifest.name.split('/', 2)[1]
          module_path = File.join(env.install_path,module_name)
          if File.directory?(module_path)
            Dir.chdir(module_path) do
              yield module_name
            end
          else
            puts "Module directory #{module_path} does not exist... How strange."
          end
        else
          puts "Found a non-git manifest: #{manifest.class}, ignoring"
        end
      end
    end


    def contributor_hash(
      repos_i_care_about = ['nova', 'glance', 'openstack', 'keystone', 'swift', 'horizon', 'cinder']
    )
      contributors = {}
      each_repo do |module_name|
        if repos_i_care_about.include?(module_name)
          logs = git_cmd('log --format=short')
          user_lines = logs.select {|x| x =~ /^Author:\s+(.*)$/ }
          user_lines.collect do |x|
            if x =~ /^Author:\s+(.*)?\s+<((\S+)@(\S+))>$/
              unless ['root', 'vagrant', 'Dan'].include?($1)
                if contributors[$1]
                  contributors[$1][:repos] = contributors[$1][:repos] | [module_name]
                else
                  contributors[$1] = {:email => $2, :repos => [module_name] }
                end
              else
                # trimming out extra users
              end
            else
              puts "Skipping unexpected line #{x}"
            end
          end
        end
      end
      contributors
    end


    # has specified the expected body.
    def testable_pull_request?(
      pr,
      admin_users,
      expected_body = 'test_it',
      options       = {}
    )
      if ! pr['merged']
        if pr['mergeable']
          if pr['comments'] > 0
            comments = Github.new(options).issues.comments.all(
              pr['base']['user']['login'],
              pr['base']['repo']['name'],
              pr['number']
            )
            puts 'going through comments'
            comments.each do |comment|
              if admin_users.include?(comment['user']['login'])
                if comment['body'] == expected_body
                  return true
                end
              end
            end
          else
            puts "PR: #{pr['number']} from #{pr['base']['repo']['name']} has no issue commments.\
            I will not test it. We only test things approved.
            "
          end
        else
          puts "PR: #{pr['number']} from #{pr['base']['repo']['name']} cannot be merged, will not test"
        end
      else
        puts "PR: #{pr['number']} from #{pr['base']['repo']['name']} was already merged, will not test"
      end
      return false
    end

    def checkedout_file
      File.join(base_dir, '.current_testing')
    end

    def checkedout_branch
      return @checkout_branch_results if @checkout_branch_results_results
      co_file = checkedout_file
      if File.exists?(co_file)
        @checkout_branch_results = YAML.load_file(co_file)
      else
        @checkout_branch_results = {}
      end
    end

    def write_checkedout_file(project_name, number)
      File.open(checkedout_file, 'w') do |fh|
        fh.write({
          :project => project_name,
          :number  => number
        }.to_yaml)
      end
    end

    def checkout_pr(project_name, number, admin_users, expected_body, options)
      # but I should write some kind of repo select
      # depends on https://github.com/peter-murach/github
      require 'github_api'

      each_repo do |repo_name|
        if repo_name == project_name
          pr = Github.new(options).pull_requests.get('puppetlabs', "puppetlabs-#{project_name}", number)
          # need to be able to override this?
          if checkedout_branch[:project]
            if checkedout_branch[:project] == project_name and checkedout_branch[:number] == number
              puts "#{project_name}/#{number} already checkout out, not doing it again"
            else
              raise(Exception, "Wanted to checkout: #{project_name}/#{number}, but #{checkedout_branch[:project]}/#{checkedout_branch[:number]} was already checked out")
            end
          end

          if testable_pull_request?(pr, admin_users, options)
            clone_url   = pr['head']['repo']['clone_url']
            remote_name = pr['head']['user']['login']
            sha         = pr['head']['sha']
            write_checkedout_file(project_name, number)
            puts 'found one that we should test'
            # TODO I am not sure how reliable all of this is going
            # to be
            remotes = git_cmd('remote')
            unless remotes.include?(remote_name)
              git_cmd("remote add #{remote_name} #{clone_url}")
            end
            git_cmd("fetch #{remote_name}")
            # TODO does that work if master has been updated?
            git_cmd("checkout #{sha}")
          end
        end
      end
    end

    # publish a string as a gist.
    # publish a link to that gist as a issue comment.
    def publish_results(project_name, number, body, options)
      require 'github_api'
      github = Github.new(options)
      gist_response = github.gists.create(
        'description' => "#{project_name}/#{number}@#{Time.now.strftime("%Y%m%dT%H%M%S%z")}",
        'public'      => true,
        'files' => {
          'file1' => {'content' => body}
        }
      )
      comments = github.issues.comments.create(
        'puppetlabs',
        "puppetlabs-#{project_name}",
        number,
        'body' => "Test results can be found here: #{gist_response.html_url}"
      )
    end


    def test_two_node(oses = [])
      require 'yaml'
      #Rake::Task['openstack:setup'.to_sym].invoke
      oses.each do |os|
        cfg = File.join(base_dir, 'config.yaml')
        yml = YAML.load_file(cfg).merge({'operatingsystem' => os})
        File.open(cfg, 'w') {|f| f.write(yml.to_yaml) }
        cmd_system('vagrant destroy -f')
        deploy_two_node
        # I should check this to see if the last line is cirros
        on_box('openstack_controller', 'sudo bash /tmp/test_nova.sh;exit $?')
      end
    end

    # iterate through each testable pull request
    def each_testable_pull_request(&block)
    end

  end
end