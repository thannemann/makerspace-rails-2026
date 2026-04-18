require 'git'

desc 'Run integration tests for frontend library'
task :integration do
  rails_repo_dir = File.expand_path(".")
  react_repo_dir = File.expand_path("tmp/makerspace-react");
  react_repo_url = ENV["REACT_REPO_URL"] || "https://github.com/thannemann/makerspace-react.git"
  if !File.directory?(react_repo_dir)
    react_git = Git.clone(react_repo_url, react_repo_dir, log: Logger.new("/dev/null")) # Silence logs to prevent cred leak
  else
    react_git = Git.open(react_repo_dir, log: Logger.new("/dev/null")) # Silence logs to prevent cred leak
    react_git.pull
  end

  react_git.fetch
  react_git.checkout(ENV["REACT_BRANCH"] || "master")

  Dir.chdir(react_repo_dir)
  system("PORT=3035 yarn && PORT=3035 yarn build") || exit(-1)
  FileUtils.mkdir_p(File.join(rails_repo_dir, "app/assets/builds"))
  FileUtils.cp(File.join(react_repo_dir, "dist/makerspace-react.js"), File.join(rails_repo_dir, "app/assets/builds"))
  Dir.chdir(rails_repo_dir)

  server_started = system("RAILS_ENV=test rake 'db:db_reset[subscriptions,payment_methods]' && RAILS_ENV=test rails s -b 0.0.0.0 -p 3035 -d")
  if server_started
    Dir.chdir(react_repo_dir)
    tests_pass = system("PORT=3035 HEADLESS=true RAILS_DIR=#{rails_repo_dir} yarn e2e")
    unless tests_pass
      puts("--------------- TESTS FAILED ---------------")
      exit(-1)
    end
  else
    puts("--------------- FAILED STARTING SERVER ---------------")
    exit(-1)
  end
end

task :start_test_server do 
  server_started = system("RAILS_ENV=test rake db:db_reset && RAILS_ENV=test rails s -b 0.0.0.0 -p 3035")
  unless server_started
    puts("--------------- FAILED STARTING SERVER ---------------")
    exit(-1)
  end
end
