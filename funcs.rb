require 'docker'
require 'yaml'
require 'markdown-tables'

def config
  @_config ||= YAML.load_file('./config.yml')
end

def scan_image(image_name, image_remove: false)
  @trivy ||= Docker::Image.create('fromImage' => 'aquasec/trivy:latest')
  ignore_path = ENV['VOLUME_PATH'] ? "#{ENV['VOLUME_PATH']}/.trivyignore" : "#{Dir.pwd}/.trivyignore"
  out_path = ENV['VOLUME_PATH'] ? "#{ENV['VOLUME_PATH']}/out" : "#{Dir.pwd}/out"

  File.open(ignore_path, mode = "w"){|f| f.write((config['ignore_cves'] || []).join("\n")) } unless File.exist?(ignore_path)

  if config['registory_domain']
    @_auth ||= {}
    @_auth[config['registory_domain']] || Docker.authenticate!('username' => ENV['GITHUB_USER'], 'password' => ENV['GITHUB_TOKEN'],
                         'serveraddress' => "https://#{config['registory_domain']}")
  end

  result = {}
  image = Docker::Image.create('fromImage' => image_name)
  vols = []
  vols << "#{ENV['VOLUME_PATH'] ? "#{ENV['VOLUME_PATH']}/cache" : "#{Dir.pwd}/cache"}:/tmp/"
  vols << "#{out_path}:/out/"
  vols << "#{ignore_path}:/ignore/.trivyignore"
  vols << '/var/run/docker.sock:/var/run/docker.sock'
  container = ::Docker::Container.create({
                                           'Image' => @trivy.id,
                                           'HostConfig' => {
                                             'Binds' => vols
                                           },
                                           'Cmd' => [
                                             '--cache-dir',
                                             '/tmp/',
                                             'image',
                                             '--ignore-unfixed',
                                             '--no-progress',
                                             '--light',
                                             '-s',
                                             'HIGH,CRITICAL',
                                             '--format',
                                             'json',
                                             '--exit-code',
                                             '1',
                                             '--ignorefile',
                                             '/ignore/.trivyignore',
                                             '--output',
                                             '/out/result.json',
                                             image_name
                                           ]
                                         })
  File.delete(File.join(out_path, "result.json"))  if File.exists?(File.join(out_path, "result.json"))
  container.start
  container.streaming_logs(stdout: true, stderr: true) { |_, chunk| puts chunk.chomp }

  container.wait(120)
  container.remove(force: true)
  image.remove(force: true) if image_remove
  JSON.parse(File.read(File.join(out_path, "result.json")))
end

def scan_result_to_issue_md(result, cve_summay={})
  return [nil, cve_summay] if result.empty? || result['Results'].none? {|r| r.key?("Vulnerabilities") }

  issue_txt = "# These images have vulnerabilites.\n"
  labels = ['target', 'type', 'name', 'path', 'installed', 'fixed', 'cve']
  data = []
  result['Results'].each do |r|
    data.concat(r["Vulnerabilities"].map do |v|
      cve_summay[v['VulnerabilityID']] ||= {}

      cve_summay[v['VulnerabilityID']]['Type'] = r['Type']
      cve_summay[v['VulnerabilityID']]['PkgName'] = v['PkgName']

      cve_summay[v['VulnerabilityID']]['PrimaryURL'] = v['PrimaryURL']

      cve_summay[v['VulnerabilityID']]['Artifacts'] ||= []
      unless cve_summay[v['VulnerabilityID']]['Artifacts'].include?(result['ArtifactName'])
        cve_summay[v['VulnerabilityID']]['Artifacts'].push(result['ArtifactName'])
      end

      [
        r["Class"] == "os-pkgs" ? "os" : r['Target'],
        r['Type'],
        v["PkgName"],
        v.fetch("PkgPath", "-"),
        v["InstalledVersion"],
        v["FixedVersion"],
        "[#{v["VulnerabilityID"]}](#{v["PrimaryURL"]})"
      ]
    end)
  end
  issue_txt << MarkdownTables.make_table(labels, data, is_rows: true)
  [issue_txt, cve_summay]
end


def cve_summary_md(cve_summary)
  labels = ['cve', 'name', 'affected images']

  data = cve_summary.map do |k,v|
    [
      "[#{k}](#{v["PrimaryURL"]})",
      v['PkgName'],
      v['Artifacts'].join("<br>")
    ]
  end
  MarkdownTables.make_table(labels, data, is_rows: true)
end
