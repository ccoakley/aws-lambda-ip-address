# This is the set of variables required to register a domain
domain_name=mydomain.com
first_name=Jane
last_name=Doe
contact_type=PERSON
address_line_1="123 Some St."
city="North Anytown"
state=CA
country_code=US
zip_code=93333
phone_number=+1.8001234567
email=admin@otherdomain.com


# check domain availability
# availability_return='{"Availability": "AVAILABLE"}'
availability_return=$(aws route53domains check-domain-availability --domain-name ${domain_name})
echo ${availability_return}
availability=$(echo ${availability_return} | jq -r '.Availability')

# If our domain is not available, we ask Amazon for 5 alternatives (this is unlikely to be helpful)
if [[ ${availability} != AVAILABLE ]]; then
  echo Expected AVAILABLE but got ${availability}
  echo "Amazon's alternatives for ${domain_name}:"
  aws route53domains get-domain-suggestions --domain-name symapi.com --suggestion-count 5 --only-available | jq -r '.SuggestionsList[] | .DomainName'
  exit 1
fi

# assemble the contact values
contact=FirstName=${first_name},LastName=${last_name},ContactType=${contact_type},AddressLine1="'"${address_line_1}"'",City=${city},State=${state},CountryCode=${country_code},ZipCode=${zip_code},PhoneNumber=${phone_number},Email=${email}
echo ${contact}

# attempt to register the domain
# if your email has already been verified, the domain should complete registration in about 15 minutes
# otherwise, check your email
register_return=$(aws route53domains register-domain --domain-name ${domain_name} --duration-in-years 1 --admin-contact "${contact}" --registrant-contact "${contact}" --tech-contact "${contact}")
echo ${register_return}
operation_id=$(echo ${register_return} | jq -r '.OperationId')
echo ${operation_id}

# get the status of the previous operation
operation_detail=$(aws route53domains get-operation-detail --operation-id ${operation_id})
echo ${operation_detail}
