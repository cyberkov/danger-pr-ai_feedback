# frozen_string_literal: true

module Danger
  # This plugin analyzes a GitLab pipeline for failed jobs, retrieves their logs,
  # sends the last 100 lines of each log to the OpenAI API for analysis,
  # and then outputs the aggregated feedback as a Danger message.
  #
  # Ensure that the following environment variables are set:
  # - GITLAB_API_TOKEN
  # - CI_API_V4_URL
  # - CI_PROJECT_ID
  # - OPENAI_API_KEY
  #
  # @example Run analysis on the current pipeline
  #          ai_feedback.analyze_pipeline
  #
  class DangerAiFeedback < Plugin

    require "uri"
    require "json"

    # Analyzes the current pipeline for failed jobs and uses ChatGPT to generate feedback.
    # The final analysis is output using Danger's `message` method.
    def analyze_pipeline
      required_vars = %w[GITLAB_API_TOKEN CI_API_V4_URL CI_PROJECT_ID OPENAI_API_KEY]
      missing_vars = required_vars.select { |var| ENV[var].to_s.strip.empty? }
      unless missing_vars.empty?
        fail "Missing environment variables: #{missing_vars.join(', ')}"
      end

      gitlab_api_token = ENV['GITLAB_API_TOKEN']
      ci_api_v4_url = ENV['CI_API_V4_URL']
      ci_project_id = ENV['CI_PROJECT_ID']
      openai_api_key = ENV['OPENAI_API_KEY']

      disclaimer_text = "_Automatically generated with OpenAI. This is only a suggestion and can be wrong._"

      # Retrieve the latest pipeline ID
      pipelines_url = "#{ci_api_v4_url}/projects/#{ci_project_id}/pipelines?per_page=1"
      pipelines_response = api_get(pipelines_url, gitlab_api_token)
      pipelines = JSON.parse(pipelines_response)
      if pipelines.empty? || pipelines.first["id"].nil?
        fail "❌ No pipeline found!"
      end
      pipeline_id = pipelines.first["id"]

      log "Checking failed jobs in pipeline #{pipeline_id}..."

      # Fetch failed jobs for this pipeline
      jobs_url = "#{ci_api_v4_url}/projects/#{ci_project_id}/pipelines/#{pipeline_id}/jobs"
      jobs_response = api_get(jobs_url, gitlab_api_token)
      jobs = JSON.parse(jobs_response)
      failed_jobs = jobs.select { |job| job["status"] == "failed" }
      failed_jobs_count = failed_jobs.count

      if failed_jobs_count.zero?
        message "✅ No failed jobs found!"
        return
      end

      log "🚨 Found #{failed_jobs_count} failed jobs."

      final_analysis = "## 🚨 Failing Pipeline detected\n"

      failed_jobs.each do |job|
        job_id   = job["id"]
        job_name = job["name"].encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
        log "Downloading log for failed job #{job_id} (#{job_name})..."
        log_url = "#{ci_api_v4_url}/projects/#{ci_project_id}/jobs/#{job_id}/trace"
        log_response = api_get(log_url, gitlab_api_token)
        log_response = log_response.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")

        if log_response.to_s.strip.empty?
          log "❌ No log found for job #{job_id}!"
          next
        end

        # Get the last 100 lines of the log
        log_lines = log_response.split("\n")
        last_100_lines = log_lines.last(100).join("\n")

        # Build the OpenAI payload
        openai_payload = {
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: "You are a DevOps and CI/CD expert providing concise and actionable feedback as a pull request comment. Format responses in a structured and readable way using Markdown. Focus on helping developers quickly understand the root cause of the failure and suggest a direct fix, without telling them to verify the fix. Use bullet points, code blocks, and **bold text** where necessary to improve readability. Keep responses short, relevant, and to the point—no follow-up steps or generic error messages."
            },
            {
              role: "user",
              content: "### Job: `#{job_name}`\n\n" \
                      "**❌ Error Details:**\n" \
                      "```plaintext\n#{last_100_lines}\n```\n" \
                      "**🔍 Root Cause:**\n" \
                      "- Identify the most relevant error message.\n\n" \
                      "**🛠️ Suggested Fix:**\n" \
                      "```bash\n# Modify this line in your script\nexit 1  # 🔴 Remove or adjust this as needed\n```\n"
            }
          ]
        }

        payload_json = JSON.generate(openai_payload)
        openai_url = "https://api.openai.com/v1/chat/completions"
        openai_response = post_request(openai_url, payload_json, openai_api_key)
        openai_response = openai_response.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")

        openai_result = JSON.parse(openai_response)
        response_text = openai_result.dig("choices", 0, "message", "content") || "No response from ChatGPT."
        log "ChatGPT response for #{job_name} received."
        final_analysis << "\n#{response_text}\n"
      end

      final_analysis << "\n#{disclaimer_text}"

      # Instead of posting comments via an API, output the final analysis as a Danger message.
      fail(final_analysis)
    end

    # Performs an HTTP GET request to the specified URL using the provided token.
    def api_get(url, token)
      response = `curl -s -H "PRIVATE-TOKEN: #{token}" "#{url}"`
      raise "API request failed!" if response.empty?
      response
    end

    # Performs an HTTP POST request to the specified URL with the given JSON data and API key.
    def post_request(url, data, openai_api_key)
      data_json = data.is_a?(String) ? data : JSON.generate(data)

      response = `curl -s -X POST "#{url}" \
        -H "Authorization: Bearer #{openai_api_key}" \
        -H "Content-Type: application/json" \
        -d '#{data_json}'`

      raise "POST request to #{url} failed!" if response.empty?
      response
    end

    # A helper method for logging messages in Danger's output.
    def log(msg)
      UI.message(msg)
    end
  end
end