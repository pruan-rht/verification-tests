Feature: SDN related test scenarios
  @admin
  Scenario: testing OCP Microshift
    Given I switch to cluster admin pseudo user
    # And the first user is cluster-admin
    Given I have a project
    And I pry
