##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core/auxiliary/password_cracker'

class MetasploitModule < Msf::Auxiliary
  include Msf::Auxiliary::PasswordCracker

  def initialize
    super(
      'Name'            => 'Password Cracker: Windows',
      'Description'     => %Q{
          This module uses John the Ripper or Hashcat to identify weak passwords that have been
        acquired from Windows systems. The module will only crack LANMAN/NTLM hashes.
        LANMAN is format 3000 in hashcat.
        NTLM is format 1000 in hashcat.
      },
      'Author'          =>
        [
          'theLightCosine',
          'hdm',
          'h00die' # hashcat integration
        ] ,
      'License'         => MSF_LICENSE,  # JtR itself is GPLv2, but this wrapper is MSF (BSD)
      'Actions'         =>
        [
          ['john', {'Description' => 'Use John the Ripper'}],
          ['hashcat', {'Description' => 'Use Hashcat'}],
        ],
      'DefaultAction' => 'john',
    )

    register_options(
      [
        OptBool.new('NTLM',  [false, 'Crack NTLM hashes', true]),
        OptBool.new('LANMAN',[false, 'Crack LANMAN hashes', true]),
        OptBool.new('INCREMENTAL',[false, 'Run in incremental mode', true]),
        OptBool.new('WORDLIST',[false, 'Run in wordlist mode', true])
      ]
    )

  end

  def show_command(cracker_instance)
    if datastore['ShowCommand']
      if action.name == 'john'
        cmd = cracker_instance.john_crack_command
      elsif action.name == 'hashcat'
        cmd = cracker_instance.hashcat_crack_command
      end
      print_status("   Cracking Command: #{cmd.join(' ')}")
    end
  end

  def print_results(tbl, cracked_hashes)
    cracked_hashes.each do |row|
      unless tbl.rows.include? row
        tbl << row
      end
    end
    tbl.to_s
  end

  def run
    def process_crack(results, hashes, cred, hash_type, method)
      return results if cred['core_id'].nil? # make sure we have good data
      # make sure we dont add the same one again
      add_it = true

      results.each do |r|
        if r[0] == cred['core_id']
          add_it = false
          break
        end
      end

      results << [cred['core_id'], hash_type, cred['username'], cred['password'], method] if add_it
      create_cracked_credential( username: cred['username'], password: cred['password'], core_id: cred['core_id'])
      results
    end

    def check_results(passwords, results, hash_type, hashes, method)
      passwords.each do |password_line|
        password_line.chomp!
        next if password_line.blank?
        fields = password_line.split(":")
        # If we don't have an expected minimum number of fields, this is probably not a hash line
        if action.name == 'john'
          next unless fields.count >=7
          cred = {}
          cred['username'] = fields.shift
          cred['core_id']  = fields.pop
          2.times { fields.pop } # Get rid of extra :
          nt_hash = fields.pop
          lm_hash = fields.pop
          id = fields.pop
          password = fields.join(':') # Anything left must be the password. This accounts for passwords with semi-colons in it
          if hash_type == 'lm' && password.blank?
            if nt_hash == Metasploit::Credential::NTLMHash::BLANK_NT_HASH
              password = ''
            else
              next
            end
          end

          # password can be nil if the hash is broken (i.e., the NT and
          # LM sides don't actually match) or if john was only able to
          # crack one half of the LM hash. In the latter case, we'll
          # have a line like:
          #  username:???????WORD:...:...:::
          cred['password'] = john_lm_upper_to_ntlm(password, nt_hash)
          next if cred['password'].nil?
          results = process_crack(results, hashes, cred, hash_type, method)
        elsif action.name == 'hashcat'
          next unless fields.count >= 2
          hash = fields.shift
          password = fields.join(':') # Anything left must be the password. This accounts for passwords with : in them
          next if hash.include?("Hashfile '") && hash.include?("' on line ") # skip error lines
          hashes.each do |h|
            if hash_type == 'lm'
              next unless h['hash'].split(':')[0] == hash
            elsif hash_type == 'nt'
              next unless h['hash'].split(':')[1] == hash
            end
            cred = {'core_id' => h['id'],
                    'username' => h['un'],
                    'password' => password}
            results = process_crack(results, hashes, cred, hash_type, method)
          end
        end
      end
      results
    end

    tbl = Rex::Text::Table.new(
      'Header'  => 'Cracked Hashes',
      'Indent'   => 1,
      'Columns' => ['DB ID', 'Hash Type', 'Username', 'Cracked Password', 'Method']
    )

    # array of hashes in jtr_format in the db, converted to an OR combined regex
    hashes_regex = []
    if datastore['LANMAN']
      hashes_regex << 'lm'
    end
    if datastore['NTLM']
      hashes_regex << 'nt'
    end

    # check we actually have an action to perform
    fail_with(Failure::BadConfig, 'Please enable at least one database type to crack') if hashes_regex.empty?

    # array of arrays for cracked passwords.
    # Inner array format: db_id, hash_type, username, password, method_of_crack
    results = []

    cracker = new_password_cracker
    cracker.cracker = action.name

    cracker_version = cracker.cracker_version
    if action.name == 'john' and not cracker_version.include?'jumbo'
      fail_with(Failure::BadConfig, 'John the Ripper JUMBO patch version required.  See https://github.com/magnumripper/JohnTheRipper')
    end
    print_good("#{action.name} Version Detected: #{cracker_version}")

    # create the hash file first, so if there aren't any hashes we can quit early
    # hashes is a reference list used by hashcat only
    cracker.hash_path, hashes = hash_file(hashes_regex)

    # generate our wordlist and close the file handle.
    wordlist = wordlist_file
    unless wordlist
      print_error('This module cannot run without a database connected. Use db_connect to connect to a database.')
      return
    end

    wordlist.close
    print_status "Wordlist file written out to #{wordlist.path}"

    cleanup_files = [cracker.hash_path, wordlist.path]

    hashes_regex.each do |format|
      # dupe our original cracker so we can safely change options between each run
      cracker_instance = cracker.dup
      cracker_instance.format = format
      if action.name == 'john'
        cracker_instance.fork = datastore['FORK']
      end

      # first check if anything has already been cracked so we don't report it incorrectly
      print_status "Checking #{format} hashes already cracked..."
      results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Already Cracked/POT')
      vprint_good(print_results(tbl, results))

      if action.name == 'john'
        print_status "Cracking #{format} hashes in single mode..."
        cracker_instance.mode_single(wordlist.path)
        show_command cracker_instance
        cracker_instance.crack do |line|
          vprint_status line.chomp
        end
        results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Single')
        vprint_good(print_results(tbl, results))

        print_status "Cracking #{format} hashes in normal mode"
        cracker_instance.mode_normal
        show_command cracker_instance
        cracker_instance.crack do |line|
          vprint_status line.chomp
        end
        results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Normal')
        vprint_good(print_results(tbl, results))
      end

      if datastore['INCREMENTAL']
        print_status "Cracking #{format} hashes in incremental mode..."
        cracker_instance.mode_incremental
        show_command cracker_instance
        cracker_instance.crack do |line|
          vprint_status line.chomp
        end
        results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Incremental')
        vprint_good(print_results(tbl, results))
      end

      if datastore['WORDLIST']
        print_status "Cracking #{format} hashes in wordlist mode..."
        cracker_instance.mode_wordlist(wordlist.path)
        # Turn on KoreLogic rules if the user asked for it
        if action.name == 'john' && datastore['KORELOGIC']
          cracker_instance.rules = 'KoreLogicRules'
          print_status "Applying KoreLogic ruleset..."
        end
        show_command cracker_instance
        cracker_instance.crack do |line|
          vprint_status line.chomp
        end

        results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Wordlist')
        vprint_good(print_results(tbl, results))
      end

      #give a final print of results
      print_good(print_results(tbl, results))
    end
    if datastore['DeleteTempFiles']
      cleanup_files.each do |f|
        File.delete(f)
      end
    end
  end

  def hash_file(hashes_regex)
    hashes = []
    wrote_hash = false
    hashlist = Rex::Quickfile.new("hashes_tmp")
    # Convert names from JtR to DB
    hashes_regex = hashes_regex.join('|')
    framework.db.creds(workspace: myworkspace, type: 'Metasploit::Credential::NTLMHash').each do |core|
      regex = Regexp.new hashes_regex
      if core.private.jtr_format =~ regex
        # only add hashes which havne't been cracked
        if already_cracked_pass(core.private.data).nil?
          if action.name == 'john'
            hashlist.puts hash_to_jtr(core)
          elsif action.name == 'hashcat'
            # hashcat hash files dont include the ID to reference back to so we build an array to reference
            hashes << {'hash' => core.private.data, 'un' => core.public.username, 'id' => core.id}
            hashlist.puts hash_to_hashcat(core)
          end
          wrote_hash = true
        end
      end
    end
    hashlist.close
    unless wrote_hash # check if we wrote anything and bail early if we didn't
      hashlist.delete
      fail_with Failure::NotFound, 'No applicable hashes in database to crack'
    end
    print_status "Hashes Written out to #{hashlist.path}"
    return hashlist.path, hashes
  end
end
