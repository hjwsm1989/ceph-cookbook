# OSD provider

action :initialize do
  b = ruby_block "Determine a new index for the OSD" do
    block do
      node[:ceph][:last_osd_index] = %x(/usr/bin/ceph osd create).strip.to_i
      node.save
    end
    action :nothing
  end

  b.run_action(:create)

  osd_index = node[:ceph][:last_osd_index]
  osd_path = @new_resource.path
  host = @new_resource.host || node[:ceph][:host] || node[:hostname]
  rack = @new_resource.rack || node[:ceph][:rack] || "rack-001"

  Chef::Log.info("Index is #{osd_index}")

  if node[:ceph][:journal_path]
    journal_location = node[:ceph][:journal_path] + "/journal.#{osd_index}"

    directory node[:ceph][:journal_path] do
      owner "root"
      group "root"
      mode "0755"
      recursive true
      action :create
    end
  else
    journal_location = osd_path + "/journal"
  end

  execute "Extract the monmap" do
    command "/usr/bin/ceph mon getmap -o /etc/ceph/monmap"
    action :run
  end

  execute "Create the fs for osd.#{osd_index}" do
    command "/usr/bin/ceph-osd -i #{osd_index} -c /dev/null --monmap /etc/ceph/monmap --osd-data=#{osd_path} --osd-journal=#{journal_location} --osd-journal-size=250 --mkfs --mkjournal"
    action :run
  end
  
  ceph_keyring "osd.#{osd_index}" do
    action [:create, :add, :store]
  end

  execute "Change the mon authentication to allow osd.#{osd_index}" do
    command "/usr/bin/ceph auth add osd.#{osd_index} osd 'allow *' mon 'allow rwx' -i /etc/ceph/osd.#{osd_index}.keyring"
    action :run
  end

  ceph_config "/etc/ceph/osd.#{osd_index}.conf" do
    osd_data [{:index => osd_index,
               :journal => journal_location,
               :journal_size => 250,
               :data => osd_path}]
  end

  execute "Add one osd to the maxosd" do
    command "ceph osd setmaxosd $(($(ceph osd getmaxosd | cut -d' ' -f3)+1))" # or should we set osd_index + 1?
    action :run
  end

  execute "Add the OSD to the crushmap" do
    command "/usr/bin/ceph osd crush add #{osd_index} osd.#{osd_index} 1 pool=default rack=#{rack} host=#{host}"
    action :run
  end
end

action :start do
  osd_path = @new_resource.path
  index = get_osd_index osd_path

  service "osd.#{index}" do
    supports :restart => true
    start_command "/etc/init.d/ceph -c /etc/ceph/osd.#{index}.conf start osd.#{index}"
    action [:start]
  end
end